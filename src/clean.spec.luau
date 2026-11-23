local json = require("@std/json")
local path = require("@std/path")
local test = require("@std/test")

local clean = require("@root/clean")
local snapshot = require("@root/core/snapshot")
local types = require("@root/types")

local function native(value: string): string
	return tostring(path.parse(value))
end

local function worktree(worktreePath: string, branch: string, primary: boolean?): types.Worktree
	return {
		path = path.parse(worktreePath),
		branch = branch,
		repository = "example/widgets",
		root = native("/src/widgets"),
		primary = primary == true,
	}
end

local worktrees: { types.Worktree } = {
	worktree("/src/widgets", "main", true),
	worktree("/src/widgets-pr-5", "fix/merged"),
	worktree("/src/widgets-pr-6", "fix/open"),
	worktree("/src/widgets-feature", "feature/hop"),
	worktree("/src/widgets/.claude/worktrees/agent-1a2b3c", "agent/merged-1a2b3c"),
	worktree("/src/widgets-pr-draft", "draft"),
}

local others: { snapshot.Entry } = {
	{
		worktree = worktree("/home/me/.hop/cache/worktrees/example/widgets-pr-9", "pr-9"),
		pullRequest = nil,
	},
}

local states: { [string]: string } = { ["5"] = "MERGED", ["6"] = "OPEN", ["9"] = "MERGED" }

local function ok(stdout: string?): types.CommandResult
	return { ok = true, exitCode = 0, stdout = stdout or "", stderr = "" }
end

-- Answers `gh pr view` with each PR's state and a head of `head-<number>`. Local branches point at
-- `head-<number>` too, except `fix/merged`, which has a commit the merge missed when `ahead` is set.
local function fakeRunner(commands: { { string } }, overrides: { [string]: types.CommandResult }?, ahead: boolean?)
	return function(argv: { string }): types.CommandResult
		table.insert(commands, argv)
		local line = table.concat(argv, " ")
		local override = overrides and overrides[line]
		if override then
			return override
		elseif argv[1] == "gh" then
			return ok(json.serialize({
				number = tonumber(argv[4]),
				url = `https://github.com/example/widgets/pull/{argv[4]}`,
				headRefName = "unused",
				headRefOid = `head-{argv[4]}`,
				state = states[argv[4]],
			}))
		elseif argv[4] == "rev-parse" then
			local branch = argv[#argv]
			local number = if branch == "refs/heads/fix/merged" then "5" else branch:match("pr%-(%d+)$")
			return ok(if ahead then "local-commit\n" else `head-{number}\n`)
		end
		return ok()
	end
end

local function gitCommands(commands: { { string } }): { string }
	local result: { string } = {}
	for _, argv in commands do
		if argv[1] == "git" then
			table.insert(result, table.concat(argv, " ", 4))
		end
	end
	return result
end

test.case("only worktrees Hop checked out count as its checkouts", function(assert)
	local found = clean.checkouts(worktrees, others)
	assert.eq(#found, 3)
	assert.eq(found[1].number, 5)
	assert.eq(found[2].number, 6)
	assert.eq(found[3].number, 9)
	assert.eq(found[3].repository, "example/widgets")
end)

test.case("merged removes checkouts of merged PRs and deletes branches at the merged head", function(assert)
	local commands: { { string } } = {}
	local outcomes = clean.clean(worktrees, others, { mode = "merged", dryRun = false, runner = fakeRunner(commands) })
	assert.eq(#outcomes, 2)
	assert.eq(outcomes[1].removed, true)
	assert.eq(outcomes[1].branchDeleted, true)
	assert.eq(outcomes[2].checkout.number, 9)
	assert.eq(outcomes[2].branchDeleted, true)
	local git = gitCommands(commands)
	assert.eq(git[1], `worktree remove {native("/src/widgets-pr-5")}`)
	assert.eq(git[2], "rev-parse --verify --quiet refs/heads/fix/merged")
	assert.eq(git[3], "branch -D fix/merged")
end)

test.case("merged keeps a branch with commits the merge missed", function(assert)
	local commands: { { string } } = {}
	local outcomes = clean.clean(
		worktrees,
		{},
		{ mode = "merged", dryRun = false, runner = fakeRunner(commands, nil, true) }
	)
	assert.eq(#outcomes, 1)
	assert.eq(outcomes[1].removed, true)
	assert.eq(outcomes[1].branchDeleted, false)
	assert.eq(table.find(gitCommands(commands), "branch -D fix/merged"), nil)
end)

test.case("all removes open PRs' checkouts too but keeps their branches", function(assert)
	local commands: { { string } } = {}
	local outcomes = clean.clean(worktrees, {}, { mode = "all", dryRun = false, runner = fakeRunner(commands) })
	assert.eq(#outcomes, 2)
	assert.eq(outcomes[2].checkout.number, 6)
	assert.eq(outcomes[2].removed, true)
	assert.eq(outcomes[2].branchDeleted, false)
	assert.eq(table.find(gitCommands(commands), "branch -D fix/open"), nil)
end)

test.case("checkouts in use, with uncommitted changes, or unknown to GitHub are kept", function(assert)
	local commands: { { string } } = {}
	local dirty = `git -C {native("/src/widgets")} worktree remove {native("/src/widgets-pr-5")}`
	local runner = fakeRunner(commands, {
		[dirty] = { ok = false, exitCode = 128, stdout = "", stderr = "fatal: contains modified files\n" },
		["gh pr view 9 --repo example/widgets --json number,title,url,headRefName,headRefOid,state,isDraft,isCrossRepository,author"] = {
			ok = false,
			exitCode = 1,
			stdout = "",
			stderr = "not found",
		},
	})
	local outcomes = clean.clean(worktrees, others, {
		mode = "all",
		dryRun = false,
		runner = runner,
		currentDirectory = native("/src/widgets-pr-6/src"),
	})
	assert.eq(outcomes[1].kept, "fatal: contains modified files")
	assert.eq(outcomes[2].kept, "it is the current directory")
	assert.eq(outcomes[3].removed, true)
	assert.eq(outcomes[3].branchDeleted, false)

	local merged = clean.clean(worktrees, others, { mode = "merged", dryRun = true, runner = runner })
	assert.eq(merged[2].kept, "unable to look up example/widgets#9")
end)

test.case("a dry run reports checkouts without running git", function(assert)
	local commands: { { string } } = {}
	local outcomes = clean.clean(worktrees, others, { mode = "all", dryRun = true, runner = fakeRunner(commands) })
	assert.eq(#outcomes, 3)
	assert.eq(outcomes[1].removed, false)
	assert.eq(outcomes[1].kept, nil)
	assert.eq(#gitCommands(commands), 0)
end)
