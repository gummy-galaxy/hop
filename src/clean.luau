local path = require("@std/path")

local defaultRun = require("@root/command")
local github = require("@root/github")
local paths = require("@root/paths")
local snapshot = require("@root/core/snapshot")
local types = require("@root/types")

-- `merged` removes Hop's checkouts whose PR has merged; `all` removes every one of them.
export type Mode = "merged" | "all"

export type Options = {
	mode: Mode,
	dryRun: boolean,
	runner: types.CommandRunner?,
	-- The worktree holding this directory is kept, so a shell or editor is never left in a deleted folder.
	currentDirectory: string?,
}

-- A worktree Hop checked out for a PR, with the clone it belongs to.
export type Checkout = {
	worktree: types.Worktree,
	root: string,
	repository: string,
	number: number,
}

export type Outcome = {
	checkout: Checkout,
	pullRequest: types.PullRequest?,
	removed: boolean,
	branchDeleted: boolean,
	-- Why a checkout that matched the mode was kept.
	kept: string?,
}

local function trim(value: string): string
	return value:match("^%s*(.-)%s*$") or ""
end

-- Hop recognizes its checkouts by where it puts them. Your own PRs go beside the repository's primary
-- checkout as `<primary>-pr-<number>`, and other people's go under ~/.hop/cache, recorded in `others`.
-- Any other worktree, such as one an agent made, is left alone even when it holds a PR.
local function checkouts(worktrees: { types.Worktree }, others: { snapshot.Entry }): { Checkout }
	local result: { Checkout } = {}
	for _, worktree in worktrees do
		local root = worktree.root
		local repository = worktree.repository
		if worktree.primary or root == nil or repository == nil then
			continue
		end
		local prefix = `{paths.basename(root)}-pr-`
		local name = paths.basename(worktree.path)
		local number = if name:sub(1, #prefix) == prefix then name:sub(#prefix + 1):match("^(%d+)$") else nil
		if number and paths.same(path.dirname(worktree.path), path.dirname(root)) then
			table.insert(
				result,
				{ worktree = worktree, root = root, repository = repository, number = assert(tonumber(number)) }
			)
		end
	end
	for _, entry in others do
		local worktree = entry.worktree
		local pullRequest = entry.pullRequest
		local repository = worktree.repository or (if pullRequest then pullRequest.repository else nil)
		local number = if pullRequest
			then pullRequest.number
			else tonumber((worktree.branch or ""):match("^pr%-(%d+)$"))
		if worktree.root and repository and number then
			table.insert(
				result,
				{ worktree = worktree, root = worktree.root, repository = repository, number = number }
			)
		end
	end
	return result
end

-- Deletes the checkout's local branch only when its tip is the merged PR's head, so no commit that
-- missed the merge is lost.
local function deleteMergedBranch(checkout: Checkout, pullRequest: types.PullRequest, run: types.CommandRunner): boolean
	local branch = checkout.worktree.branch
	if branch == nil or pullRequest.state ~= "MERGED" or pullRequest.head == nil then
		return false
	end
	local ok, tip =
		pcall(run, { "git", "-C", checkout.root, "rev-parse", "--verify", "--quiet", `refs/heads/{branch}` })
	if not ok or not tip.ok or trim(tip.stdout) ~= pullRequest.head then
		return false
	end
	local deleted, response = pcall(run, { "git", "-C", checkout.root, "branch", "-D", branch })
	return deleted and response.ok
end

-- Removes Hop's checkouts that match the mode, and reports each one. Checkouts whose PR has not
-- merged are left out of the report in `merged` mode. Git refuses to remove a worktree with
-- uncommitted changes, so those are kept with Git's reason.
local function clean(worktrees: { types.Worktree }, others: { snapshot.Entry }, options: Options): { Outcome }
	local run = options.runner or defaultRun
	local outcomes: { Outcome } = {}
	for _, checkout in checkouts(worktrees, others) do
		local lookedUp, found = pcall(github.viewPullRequest, checkout.repository, checkout.number, run)
		local pullRequest: types.PullRequest? = if lookedUp then found else nil
		local outcome: Outcome =
			{ checkout = checkout, pullRequest = pullRequest, removed = false, branchDeleted = false }
		if options.mode == "merged" then
			if not lookedUp then
				outcome.kept = `unable to look up {checkout.repository}#{checkout.number}`
				table.insert(outcomes, outcome)
				continue
			elseif pullRequest == nil or pullRequest.state ~= "MERGED" then
				continue
			end
		end
		table.insert(outcomes, outcome)

		local current = options.currentDirectory
		if current and paths.below(checkout.worktree.path, current) then
			outcome.kept = "it is the current directory"
		elseif not options.dryRun then
			local ok, response =
				pcall(run, { "git", "-C", checkout.root, "worktree", "remove", tostring(checkout.worktree.path) })
			if not ok then
				outcome.kept = `unable to run git: {response}`
			elseif not response.ok then
				outcome.kept = trim(response.stderr)
			else
				outcome.removed = true
				outcome.branchDeleted = pullRequest ~= nil and deleteMergedBranch(checkout, pullRequest, run)
			end
		end
	end
	return outcomes
end

return table.freeze({
	checkouts = checkouts,
	clean = clean,
})
