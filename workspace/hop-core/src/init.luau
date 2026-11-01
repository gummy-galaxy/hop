--[[
	Hop's public entry point. It finds your worktrees and their pull requests,
	your recent Cursor and Claude Code sessions, and the worktree an expression
	names, as `hop list`, `hop recent`, and `hop to` do. It returns what it finds
	and leaves printing, choosing between matches, and opening an editor to the
	caller. Only `to` changes anything on disk: it can add a worktree or clone a
	repository to check out a pull request.

	Every function takes a context from `context()`. Its defaults read your
	machine: Git, `gh`, the Cursor and Claude Code data folders, and Hop's cache
	in `~/.hop`. Options replace any of those, which is how specs run without
	them.
]]
local fs = require("@std/fs")
local path = require("@std/path")
local process = require("@std/process")

local Claude = require("@root/providers/claude")
local Cursor = require("@root/providers/cursor")
local cache = require("@root/cache")
local checkout = require("@root/checkout")
local defaultRun = require("@root/command")
local git = require("@root/git")
local github = require("@root/github")
local loadConfig = require("@root/config/load")
local matchWorktrees = require("@root/core/matchWorktrees")
local others = require("@root/others")
local paths = require("@root/paths")
local providers = require("@root/providers")
local resolve = require("@root/core/resolve")
local snapshot = require("@root/core/snapshot")
local types = require("@root/types")

export type CommandRunner = types.CommandRunner
export type Worktree = types.Worktree
export type PullRequest = types.PullRequest
export type Session = types.Session
export type Snapshot = snapshot.Snapshot
export type Entry = snapshot.Entry
export type CheckoutTarget = resolve.CheckoutTarget

export type Options = {
	runner: types.CommandRunner?,
	homeDirectory: path.Pathlike?,
	loadSessions: (() -> { types.Session })?,
	loadWorktrees: (() -> { types.Worktree })?,
	cache: cache.Cache?,
	others: others.Store?,
	now: (() -> number)?,
	activity: resolve.Activity?,
}

export type Context = {
	runner: types.CommandRunner,
	homeDirectory: string,
	loadWorktrees: () -> { types.Worktree },
	loadSessions: () -> { types.Session },
	cache: cache.Cache,
	others: others.Store,
	now: () -> number,
	activity: resolve.Activity,
}

export type ListOptions = {
	refresh: boolean?,
	pullRequests: boolean?,
}

-- `others` holds the worktrees Hop checked out under `~/.hop/cache` for other
-- people's pull requests. `cached` is true when the snapshot came from Hop's
-- cache rather than being rebuilt just now.
export type Listing = {
	snapshot: snapshot.Snapshot,
	others: { snapshot.Entry },
	cached: boolean,
}

export type RecentOptions = {
	limit: number?,
	repository: string?,
	agent: ("cursor" | "claude")?,
	pullRequests: boolean?,
}

export type RecentItem = {
	session: types.Session,
	worktree: types.Worktree?,
	pullRequest: types.PullRequest?,
}

export type Checkout = {
	target: resolve.CheckoutTarget,
	-- False when Hop found an existing worktree on the pull request's branch and
	-- used it instead of adding one.
	created: boolean,
}

-- The worktrees an expression matched. When the expression named a pull
-- request that had no worktree yet, Hop checks it out, `checkout` names that
-- pull request, and `entries` holds only its worktree.
export type Destination = {
	entries: { snapshot.Entry },
	checkout: Checkout?,
}

local function context(options: Options?): Context
	local resolved: Options = options or {}
	local runner = resolved.runner or defaultRun
	local home = tostring(resolved.homeDirectory or process.homedir())
	return {
		runner = runner,
		homeDirectory = home,
		loadWorktrees = resolved.loadWorktrees or function()
			local config = loadConfig({ homeDirectory = home })
			return git.discover(config.roots, { runner = runner })
		end,
		loadSessions = resolved.loadSessions or function()
			return providers.collect({
				Cursor.new({ homeDirectory = home, runner = runner }),
				Claude.new({ homeDirectory = home }),
			})
		end,
		cache = resolved.cache or cache.new(home),
		others = resolved.others or others.new(home),
		now = resolved.now or function()
			return os.time()
		end,
		activity = resolved.activity or git.lastActivity,
	}
end

-- Your worktrees, leaving out others' work that discovery reaches through your clones.
local function ownWorktrees(deps: Context): { types.Worktree }
	local result: { types.Worktree } = {}
	for _, worktree in deps.loadWorktrees() do
		if not others.contains(deps.homeDirectory, worktree.path) then
			table.insert(result, worktree)
		end
	end
	return result
end

-- Returns the cached snapshot when allowed, otherwise rebuilds it from Git and GitHub.
-- Rebuilds without a complete GitHub lookup are not cached so they never discard known PR
-- associations. A cache that cannot be written only costs the next command a rebuild.
local function loadSnapshot(deps: Context, refresh: boolean, includePullRequests: boolean): (snapshot.Snapshot, boolean)
	if not refresh then
		local cached = deps.cache.read()
		if cached then
			return cached, true
		end
	end
	local worktrees = ownWorktrees(deps)
	local pullRequests: { types.PullRequest } = {}
	local complete = false
	if includePullRequests then
		pullRequests, complete = github.listPullRequests(worktrees, deps.runner)
	end
	local value = snapshot.build(worktrees, pullRequests, deps.now())
	if complete then
		pcall(deps.cache.write, value)
	end
	return value, false
end

local function worktreeForSession(session: types.Session, worktrees: { types.Worktree }): types.Worktree?
	if session.directory then
		for _, worktree in worktrees do
			if paths.same(worktree.path, session.directory) then
				return worktree
			end
		end
	end
	if session.branchAtSessionTime then
		local matches = matchWorktrees(worktrees, session.branchAtSessionTime)
		if matches[1] then
			return matches[1]
		end
	end
	if session.directory then
		local matches = matchWorktrees(worktrees, session.directory)
		if matches[1] then
			return matches[1]
		end
	end
	return nil
end

local function recentItems(sessions: { types.Session }, worktrees: { types.Worktree }): { RecentItem }
	local items: { RecentItem } = {}
	for _, session in sessions do
		table.insert(items, {
			session = session,
			worktree = worktreeForSession(session, worktrees),
			pullRequest = nil,
		})
	end
	return items
end

local function filteredRecent(items: { RecentItem }, options: RecentOptions): { RecentItem }
	local result: { RecentItem } = {}
	local limit = options.limit or math.huge
	if limit == 0 then
		return result
	end
	local repositoryFilter = if options.repository then options.repository:lower() else nil
	for _, item in items do
		if options.agent and item.session.agent ~= options.agent then
			continue
		end
		if repositoryFilter then
			local repository = if item.worktree and item.worktree.repository
				then item.worktree.repository:lower()
				else ""
			local directory = (if item.worktree then tostring(item.worktree.path) else item.session.directory or ""):lower()
			if not repository:find(repositoryFilter, 1, true) and not directory:find(repositoryFilter, 1, true) then
				continue
			end
		end
		table.insert(result, item)
		if #result >= limit then
			break
		end
	end
	return result
end

local function attachPullRequests(items: { RecentItem }, runner: types.CommandRunner)
	local worktrees: { types.Worktree } = {}
	for _, item in items do
		if item.worktree then
			table.insert(worktrees, item.worktree)
		end
	end
	local pullRequests = github.indexPullRequests((github.listPullRequests(worktrees, runner)))
	for _, item in items do
		local worktree = item.worktree
		if worktree and worktree.repository and worktree.branch then
			item.pullRequest = pullRequests[github.pullRequestKey(worktree.repository, worktree.branch)]
		end
	end
end

-- Your worktrees with their pull requests, your open pull requests that have
-- no worktree, and the worktrees Hop checked out for others' pull requests.
-- Reads the cache unless `refresh` is set or there is none. When Hop rebuilds
-- it, `pullRequests = false` skips GitHub and leaves the cache alone.
local function list(deps: Context, options: ListOptions?): Listing
	local selected: ListOptions = options or {}
	local value, cached = loadSnapshot(deps, selected.refresh == true, selected.pullRequests ~= false)
	return {
		snapshot = value,
		others = deps.others.read(),
		cached = cached,
	}
end

-- Your Cursor and Claude Code sessions, most recent first. Each comes with the
-- worktree it most likely ran in, matched by folder and then by branch, and
-- that worktree's pull request. `pullRequests = false` skips GitHub. Without a
-- `limit`, every session is returned.
local function recent(deps: Context, options: RecentOptions?): { RecentItem }
	local selected: RecentOptions = options or {}
	local items = filteredRecent(recentItems(deps.loadSessions(), deps.loadWorktrees()), selected)
	if selected.pullRequests ~= false then
		attachPullRequests(items, deps.runner)
	end
	return items
end

local function noWorktreeMessage(expression: string, pullRequests: { types.PullRequest }): string
	if #pullRequests == 0 then
		return `nothing matches "{expression}"`
	end
	local lines = { `no local worktree for "{expression}"; matching pull requests:` }
	for _, pullRequest in pullRequests do
		table.insert(lines, `  {pullRequest.repository}#{pullRequest.number} {pullRequest.url}`)
	end
	return table.concat(lines, "\n")
end

local function hasMissingWorktree(entries: { snapshot.Entry }): boolean
	for _, entry in entries do
		if not fs.exists(entry.worktree.path) then
			return true
		end
	end
	return false
end

-- Finds the worktrees an expression names. The expression is a pull request
-- reference such as `repo#123` or search words. A reference to a pull request
-- with no worktree checks it out; search words only ever match existing
-- worktrees. Errors when nothing matches, or when search words match only pull
-- requests without a worktree.
--
-- Your worktrees and open PRs come first, then others' work Hop already checked out. Anything else
-- refreshes a cached snapshot once before checking out a PR or giving up.
local function to(deps: Context, text: string): Destination
	assert(text:match("%S"), "expression is empty")
	local expression = resolve.parse(text)
	local value, cached = loadSnapshot(deps, false, true)
	local resolution = resolve.resolve(value, expression, deps.activity)
	if cached and hasMissingWorktree(resolution.entries) then
		-- The cache may list a worktree that was removed.
		value, cached = loadSnapshot(deps, true, true)
		resolution = resolve.resolve(value, expression, deps.activity)
	end
	local otherEntries = deps.others.read()
	local target: resolve.CheckoutTarget? = nil
	if #resolution.entries == 0 then
		if #resolution.pullRequests == 0 then
			local visited = resolve.resolveOthers(otherEntries, expression)
			if #visited > 0 then
				return { entries = visited }
			end
		end
		if cached then
			-- The cache may predate a worktree an agent just created or one of your new PRs. Checking out
			-- from it could add a branch that is already checked out or file your PR as someone else's.
			value = loadSnapshot(deps, true, true)
			resolution = resolve.resolve(value, expression, deps.activity)
		end
		if #resolution.entries == 0 and #resolution.pullRequests == 0 then
			target = resolve.checkoutTarget(value, expression, otherEntries)
		end
	end

	if #resolution.entries > 0 then
		return { entries = resolution.entries }
	elseif expression.kind == "query" or #resolution.pullRequests > 1 then
		error(noWorktreeMessage(text, resolution.pullRequests), 0)
	elseif #resolution.pullRequests == 1 then
		local pullRequest = resolution.pullRequests[1]
		local own = { repository = pullRequest.repository, number = pullRequest.number }
		local result = checkout.pullRequest(value, own, deps.runner)
		deps.cache.write(value)
		return { entries = { result.entry }, checkout = { target = own, created = result.created } }
	end
	if target == nil then
		error(noWorktreeMessage(text, {}), 0)
	end

	local result = checkout.reference(value, target, {
		runner = deps.runner,
		homeDirectory = deps.homeDirectory,
		findClone = function(repository)
			for _, worktree in ownWorktrees(deps) do
				if worktree.primary and worktree.repository and worktree.repository:lower() == repository:lower() then
					return worktree
				end
			end
			return nil
		end,
	})
	if result.other then
		-- Read again so a checkout another Hop process finished meanwhile keeps its record.
		local latest = deps.others.read()
		for index = #latest, 1, -1 do
			if tostring(latest[index].worktree.path) == tostring(result.entry.worktree.path) then
				table.remove(latest, index)
			end
		end
		table.insert(latest, result.entry)
		deps.others.write(latest)
	else
		deps.cache.write(value)
	end
	return { entries = { result.entry }, checkout = { target = target, created = result.created } }
end

return table.freeze({
	context = context,
	list = list,
	recent = recent,
	to = to,
})
