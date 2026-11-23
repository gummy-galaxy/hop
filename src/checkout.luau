local fs = require("@std/fs")
local path = require("@std/path")

local defaultRun = require("@root/command")
local git = require("@root/git")
local github = require("@root/github")
local others = require("@root/others")
local resolve = require("@root/core/resolve")
local snapshot = require("@root/core/snapshot")
local types = require("@root/types")

export type Result = {
	entry: snapshot.Entry,
	created: boolean,
}

export type ReferenceOptions = {
	runner: types.CommandRunner?,
	homeDirectory: string,
	-- Rediscovers a clone the cache does not know yet, so Hop never clones a repository you already have.
	findClone: (repository: string) -> types.Worktree?,
}

export type ReferenceResult = {
	entry: snapshot.Entry,
	created: boolean,
	-- The worktree belongs with others' work rather than in the snapshot.
	other: boolean,
}

local function sameRepository(left: string?, right: string): boolean
	return left ~= nil and left:lower() == right:lower()
end

-- Any worktree of the repository knows its primary checkout's path, so prefer the primary but accept any.
local function checkoutOf(value: snapshot.Snapshot, repository: string): types.Worktree?
	local found: types.Worktree? = nil
	for _, entry in value.entries do
		local worktree = entry.worktree
		if sameRepository(worktree.repository, repository) then
			if worktree.primary then
				return worktree
			end
			found = found or worktree
		end
	end
	return found
end

local function removePullRequest(value: snapshot.Snapshot, pullRequest: types.PullRequest)
	for index = #value.pullRequests, 1, -1 do
		local candidate = value.pullRequests[index]
		if candidate.number == pullRequest.number and sameRepository(candidate.repository, pullRequest.repository) then
			table.remove(value.pullRequests, index)
		end
	end
end

-- Fork PRs get a local branch named after the PR, since their head branch name belongs to the fork.
local function localBranch(pullRequest: types.PullRequest, crossRepository: boolean): string
	return if crossRepository then `pr-{pullRequest.number}` else pullRequest.branch
end

-- GitHub's spelling of the PR's repository, which a remote or a typed reference need not match.
local function canonicalRepository(pullRequest: types.PullRequest): string
	return pullRequest.url:match("^https?://[^/]+/([^/]+/[^/]+)/pull/%d+") or pullRequest.repository
end

local function link(
	primary: string,
	branch: string,
	details: types.PullRequest,
	crossRepository: boolean,
	runner: types.CommandRunner?
)
	git.linkPullRequest({
		primary = primary,
		branch = branch,
		repository = canonicalRepository(details),
		number = details.number,
		head = if crossRepository then nil else details.branch,
	}, runner)
end

-- The clone to configure when `worktree` is a PR-named checkout that is not linked to its PR yet.
-- Hop checked out `pr-<number>` worktrees without links before, so reopening one links it.
local function unlinkedClone(worktree: types.Worktree, number: number, runner: types.CommandRunner?): string?
	if worktree.branch ~= `pr-{number}` then
		return nil
	end
	local primary = worktree.root or tostring(worktree.path)
	return if git.isPullRequestLinked(primary, `pr-{number}`, runner) then nil else primary
end

local function linkReused(
	worktree: types.Worktree,
	details: types.PullRequest,
	crossRepository: boolean,
	runner: types.CommandRunner?
)
	local primary = unlinkedClone(worktree, details.number, runner)
	if primary then
		link(primary, `pr-{details.number}`, details, crossRepository, runner)
	end
end

-- Links a PR-named worktree that `hop to` reopens straight from what Hop recorded. Only an unlinked
-- worktree costs a GitHub lookup, and a failed lookup still opens it.
local function relink(entry: snapshot.Entry, runner: types.CommandRunner?)
	local pullRequest = entry.pullRequest
	if pullRequest == nil or unlinkedClone(entry.worktree, pullRequest.number, runner) == nil then
		return
	end
	local ok, details, crossRepository =
		pcall(github.viewPullRequest, pullRequest.repository, pullRequest.number, runner)
	if ok then
		link(
			entry.worktree.root or tostring(entry.worktree.path),
			`pr-{pullRequest.number}`,
			details,
			crossRepository,
			runner
		)
	end
end

-- Opens a PR without a worktree. A worktree already on the PR's branch is reused; otherwise a new
-- one is added beside the repository's primary checkout as `<primary>-pr-<number>`. The snapshot is
-- updated in place so it can be cached.
local function pullRequest(
	value: snapshot.Snapshot,
	target: resolve.CheckoutTarget,
	runner: types.CommandRunner?
): Result
	local primary = checkoutOf(value, target.repository)
	if primary == nil or primary.repository == nil then
		error(`no local clone of {target.repository} was found; clone it under one of Hop's roots first`, 0)
	end
	local repository = primary.repository
	local details, crossRepository = github.viewPullRequest(repository, target.number, runner)
	local branch = localBranch(details, crossRepository)

	-- A same-repository PR's head is its branch, so a worktree on that branch already holds this PR's code
	-- even when the cache links it to another open PR from the same branch. Fork PRs use `pr-<number>`.
	for _, entry in value.entries do
		if entry.worktree.branch == branch and sameRepository(entry.worktree.repository, repository) then
			entry.pullRequest = entry.pullRequest or details
			removePullRequest(value, details)
			linkReused(entry.worktree, details, crossRepository, runner)
			return { entry = entry, created = false }
		end
	end

	local root = primary.root or tostring(primary.path)
	local destination = path.join(path.dirname(root), `{path.basename(root)}-pr-{details.number}`)
	if fs.exists(destination) then
		error(`{destination} already exists but is not on {branch}`, 0)
	end
	git.addPullRequestWorktree({
		primary = root,
		path = tostring(destination),
		number = details.number,
		branch = branch,
		fromPullRef = crossRepository,
	}, runner)
	if crossRepository then
		link(root, branch, details, crossRepository, runner)
	end

	local entry: snapshot.Entry = {
		worktree = {
			path = destination,
			branch = branch,
			repository = repository,
			root = root,
			head = nil,
			defaultBranch = primary.defaultBranch,
			primary = false,
		},
		pullRequest = details,
	}
	table.insert(value.entries, entry)
	removePullRequest(value, details)
	return { entry = entry, created = true }
end

-- One of your worktrees on `branch`, from the snapshot or, failing that, from the clone itself.
local function ownWorktree(
	value: snapshot.Snapshot,
	primary: types.Worktree,
	branch: string,
	options: ReferenceOptions
): snapshot.Entry?
	local repository = primary.repository
	for _, entry in value.entries do
		if entry.worktree.branch == branch and sameRepository(entry.worktree.repository, repository or "") then
			return entry
		end
	end
	local root = primary.root or tostring(primary.path)
	local run = options.runner or defaultRun
	local ok, response = pcall(run, { "git", "-C", root, "worktree", "list", "--porcelain" })
	if not ok or not response.ok then
		return nil
	end
	for _, worktree in git.parseWorktreeList(response.stdout, repository, root, primary.defaultBranch) do
		if worktree.branch == branch and not others.contains(options.homeDirectory, worktree.path) then
			local entry: snapshot.Entry = { worktree = worktree, pullRequest = nil }
			table.insert(value.entries, entry)
			return entry
		end
	end
	return nil
end

-- Opens a PR that neither the cache nor others' work knows. A worktree of yours already on its branch
-- is yours; otherwise the PR is someone else's and is checked out under ~/.hop/cache, linked to your
-- clone when you have one and to a fresh clone in ~/.hop/cache/repos when you do not. Others' PRs are
-- always fetched from `refs/pull/<number>/head` into `pr-<number>`, so PRs sharing a head branch never
-- compete for one local branch.
local function reference(
	value: snapshot.Snapshot,
	target: resolve.CheckoutTarget,
	options: ReferenceOptions
): ReferenceResult
	local primary = checkoutOf(value, target.repository) or options.findClone(target.repository)
	local repository = if primary and primary.repository then primary.repository else target.repository
	local details, crossRepository = github.viewPullRequest(repository, target.number, options.runner)
	local branch = localBranch(details, crossRepository)

	if primary then
		local own = ownWorktree(value, primary, branch, options)
		if own then
			own.pullRequest = own.pullRequest or details
			removePullRequest(value, details)
			linkReused(own.worktree, details, crossRepository, options.runner)
			return { entry = own, created = false, other = false }
		end
	end

	local root: string
	if primary then
		root = primary.root or tostring(primary.path)
	else
		local clone = others.clonePath(options.homeDirectory, repository)
		if not fs.exists(clone) then
			github.cloneRepository(repository, tostring(clone), options.runner)
		end
		root = tostring(clone)
	end

	local destination = others.worktreePath(options.homeDirectory, repository, details.number)
	if fs.exists(destination) then
		error(`{destination} already exists but Hop has no record of it; remove it and try again`, 0)
	end
	local otherBranch = `pr-{details.number}`
	git.addPullRequestWorktree({
		primary = root,
		path = tostring(destination),
		number = details.number,
		branch = otherBranch,
		fromPullRef = true,
	}, options.runner)
	link(root, otherBranch, details, crossRepository, options.runner)

	return {
		entry = {
			worktree = {
				path = destination,
				branch = otherBranch,
				repository = repository,
				root = root,
				head = nil,
				defaultBranch = if primary then primary.defaultBranch else nil,
				primary = false,
			},
			pullRequest = details,
		},
		created = true,
		other = true,
	}
end

return table.freeze({
	pullRequest = pullRequest,
	reference = reference,
	relink = relink,
})
