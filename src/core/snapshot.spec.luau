local path = require("@std/path")
local test = require("@std/test")

local snapshot = require("@root/core/snapshot")
local types = require("@root/types")

local function pullRequest(number: number, branch: string): types.PullRequest
	return {
		number = number,
		url = `https://github.com/example/widgets/pull/{number}`,
		branch = branch,
		repository = "example/widgets",
		state = "OPEN",
	}
end

test.case("snapshots link a worktree to the PR for the branch it tracks", function(assert)
	local value = snapshot.build({
		{
			path = path.parse("/src/widgets-hop"),
			branch = "agent/hop-1a2b3c",
			upstream = "feature/hop",
			repository = "example/widgets",
			primary = false,
		},
	}, { pullRequest(42, "feature/hop") }, 0)
	local linked = value.entries[1].pullRequest
	assert.eq(linked and linked.number, 42)
	assert.eq(#value.pullRequests, 0)
end)

test.case("snapshots prefer the local branch's PR and ignore a tracked default branch", function(assert)
	local value = snapshot.build({
		{
			path = path.parse("/src/widgets-arrows"),
			branch = "agent/arrows",
			upstream = "main",
			repository = "example/widgets",
			defaultBranch = "main",
			primary = false,
		},
		{
			path = path.parse("/src/widgets-fix"),
			branch = "agent/fix-1a2b3c",
			upstream = "main",
			repository = "example/widgets",
			defaultBranch = "main",
			primary = false,
		},
	}, { pullRequest(7, "agent/arrows"), pullRequest(8, "main") }, 0)
	local arrows = value.entries[1].pullRequest
	assert.eq(arrows and arrows.number, 7)
	assert.eq(value.entries[2].pullRequest, nil)
	assert.eq(#value.pullRequests, 1)
	assert.eq(value.pullRequests[1].number, 8)
end)
