local json = require("@std/json")
local path = require("@std/path")

local github = require("@root/github")
local paths = require("@root/paths")
local types = require("@root/types")

export type Entry = {
	worktree: types.Worktree,
	pullRequest: types.PullRequest?,
}

-- Everything Hop knows about local work at one moment: every worktree with its
-- associated PR, plus open PRs that have no local worktree yet.
export type Snapshot = {
	generatedAt: number,
	entries: { Entry },
	pullRequests: { types.PullRequest },
}

-- Repositories without an `origin/HEAD` fall back to the conventional default branch names.
local function namesDefaultBranch(branch: string, defaultBranch: string?): boolean
	if defaultBranch then
		return branch == defaultBranch
	end
	return branch == "main" or branch == "master"
end

-- The head branches a PR for this worktree could have: its local branch, then the branch it tracks on
-- `origin` when that has another name. A branch created from `origin/main` tracks the default branch,
-- but its PR is on the local branch. Matching that upstream would link the worktree to a release or
-- sync PR opened from the default branch, so it is left out.
local function headBranches(worktree: types.Worktree): { string }
	local result: { string } = {}
	local branch = worktree.branch
	if branch == nil then
		return result
	end
	table.insert(result, branch)
	local upstream = worktree.upstream
	if upstream and upstream ~= branch and not namesDefaultBranch(upstream, worktree.defaultBranch) then
		table.insert(result, upstream)
	end
	return result
end

local function build(worktrees: { types.Worktree }, pullRequests: { types.PullRequest }, generatedAt: number): Snapshot
	local index = github.indexPullRequests(pullRequests)
	local used: { [string]: boolean } = {}
	local entries: { Entry } = {}
	for _, worktree in worktrees do
		local pullRequest: types.PullRequest? = nil
		if worktree.repository then
			for _, branch in headBranches(worktree) do
				local key = github.pullRequestKey(worktree.repository, branch)
				if index[key] then
					pullRequest = index[key]
					used[key] = true
					break
				end
			end
			if worktree.branch then
				used[github.pullRequestKey(worktree.repository, worktree.branch)] = true
			end
		end
		table.insert(entries, { worktree = worktree, pullRequest = pullRequest })
	end

	local unmatched: { types.PullRequest } = {}
	for key, pullRequest in index do
		if not used[key] and pullRequest.state == "OPEN" then
			table.insert(unmatched, pullRequest)
		end
	end
	table.sort(unmatched, function(left: types.PullRequest, right: types.PullRequest)
		if left.repository == right.repository then
			return left.number > right.number
		end
		return left.repository < right.repository
	end)
	return { generatedAt = generatedAt, entries = entries, pullRequests = unmatched }
end

local function repositoryName(worktree: types.Worktree): string
	if worktree.repository then
		return worktree.repository:match("/(.+)$") or worktree.repository
	end
	local root = worktree.root or tostring(worktree.path)
	return paths.basename(root)
end

local function isDefaultBranch(worktree: types.Worktree): boolean
	local branch = worktree.branch
	return branch ~= nil and namesDefaultBranch(branch, worktree.defaultBranch)
end

local function pullRequestJson(pullRequest: types.PullRequest): json.Object
	return {
		repository = pullRequest.repository,
		number = pullRequest.number,
		title = pullRequest.title,
		url = pullRequest.url,
		branch = pullRequest.branch,
		state = pullRequest.state,
		draft = pullRequest.draft,
		author = pullRequest.author,
	}
end

-- `activity` adds each worktree's last use, which changes too often to cache.
local function entriesToJson(entries: { Entry }, activity: ((types.Worktree) -> number)?): json.Array
	local worktrees: json.Array = {}
	for _, entry in entries do
		local worktree = entry.worktree
		local repository: json.Object = {
			name = repositoryName(worktree),
			root = worktree.root,
			remote = worktree.repository,
			defaultBranch = worktree.defaultBranch,
		}
		local item: json.Object = {
			repository = repository,
			path = tostring(worktree.path),
			branch = worktree.branch,
			upstream = worktree.upstream,
			head = worktree.head,
			primary = worktree.primary,
			onDefaultBranch = isDefaultBranch(worktree),
			lastActivity = if activity then activity(worktree) else nil,
			pr = if entry.pullRequest then pullRequestJson(entry.pullRequest) else nil,
		}
		table.insert(worktrees, item)
	end
	return worktrees
end

local function toJson(snapshot: Snapshot, activity: ((types.Worktree) -> number)?): json.Object
	local pullRequests: json.Array = {}
	for _, pullRequest in snapshot.pullRequests do
		table.insert(pullRequests, pullRequestJson(pullRequest))
	end
	return {
		generatedAt = snapshot.generatedAt,
		worktrees = entriesToJson(snapshot.entries, activity),
		pullRequests = pullRequests,
	}
end

local function optionalString(value: json.Value): string?
	return if type(value) == "string" then value else nil
end

local function pullRequestFromJson(value: json.Value): types.PullRequest?
	local object = json.asObject(value)
	if object == nil then
		return nil
	end
	local number = object.number
	local url = object.url
	local branch = object.branch
	local repository = object.repository
	if
		type(number) ~= "number"
		or type(url) ~= "string"
		or type(branch) ~= "string"
		or type(repository) ~= "string"
	then
		return nil
	end
	local draft = object.draft
	return {
		number = number,
		url = url,
		branch = branch,
		repository = repository,
		title = optionalString(object.title),
		state = optionalString(object.state),
		draft = if type(draft) == "boolean" then draft else nil,
		author = optionalString(object.author),
	}
end

-- Returns nil unless every item is a worktree this version of Hop wrote.
local function entriesFromJson(value: json.Value): { Entry }?
	local worktrees = json.asArray(value)
	if worktrees == nil then
		return nil
	end
	local entries: { Entry } = {}
	for _, item in worktrees do
		local worktreeObject = json.asObject(item)
		local worktreePath = if worktreeObject then worktreeObject.path else nil
		if worktreeObject == nil or type(worktreePath) ~= "string" then
			return nil
		end
		local repository: json.Object = json.asObject(worktreeObject.repository) or {}
		table.insert(entries, {
			worktree = {
				path = path.parse(worktreePath),
				branch = optionalString(worktreeObject.branch),
				upstream = optionalString(worktreeObject.upstream),
				repository = optionalString(repository.remote),
				root = optionalString(repository.root),
				head = optionalString(worktreeObject.head),
				defaultBranch = optionalString(repository.defaultBranch),
				primary = worktreeObject.primary == true,
			},
			pullRequest = pullRequestFromJson(worktreeObject.pr),
		})
	end
	return entries
end

-- Returns nil for anything that is not a snapshot this version of Hop wrote.
local function fromJson(value: json.Value): Snapshot?
	local object = json.asObject(value)
	if object == nil then
		return nil
	end
	local generatedAt = object.generatedAt
	local entries = entriesFromJson(object.worktrees)
	local pullRequests = json.asArray(object.pullRequests)
	if type(generatedAt) ~= "number" or entries == nil or pullRequests == nil then
		return nil
	end

	local unmatched: { types.PullRequest } = {}
	for _, item in pullRequests do
		local pullRequest = pullRequestFromJson(item)
		if pullRequest then
			table.insert(unmatched, pullRequest)
		end
	end
	return { generatedAt = generatedAt, entries = entries, pullRequests = unmatched }
end

return table.freeze({
	build = build,
	entriesFromJson = entriesFromJson,
	entriesToJson = entriesToJson,
	fromJson = fromJson,
	headBranches = headBranches,
	isDefaultBranch = isDefaultBranch,
	repositoryName = repositoryName,
	toJson = toJson,
})
