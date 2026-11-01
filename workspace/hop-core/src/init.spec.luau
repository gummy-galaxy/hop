local path = require("@std/path")
local test = require("@std/test")

local hop = require("@root")
local providers = require("@root/providers")
local snapshot = require("@root/core/snapshot")
local types = require("@root/types")

local worktrees: { types.Worktree } = {
	{
		path = path.parse("/src/widgets"),
		branch = "main",
		repository = "example/widgets",
		primary = true,
	},
	{
		path = path.parse("/src/widgets-feature"),
		branch = "feature/hop",
		repository = "example/widgets",
		primary = false,
	},
}

local sessions: { types.Session } = {
	{
		agent = "cursor",
		id = "cursor-1",
		title = "Implement Hop",
		directory = "/src/widgets-feature",
		branchAtSessionTime = "feature/hop",
		updatedAt = 200,
		messages = providers.emptyMessages,
	},
	{
		agent = "claude",
		id = "claude-1",
		title = "Review widgets",
		directory = "/src/widgets",
		branchAtSessionTime = "main",
		updatedAt = 100,
		messages = providers.emptyMessages,
	},
}

-- A context that never runs a command or reads Hop's files. Commands it is
-- asked to run are recorded in `commands` and answered with an empty success.
-- Its cache keeps what is written to it, and each write is also kept in
-- `writes`.
local function fakeContext(): (hop.Context, { { string } }, { snapshot.Snapshot })
	local commands: { { string } } = {}
	local writes: { snapshot.Snapshot } = {}
	local cached: snapshot.Snapshot? = nil
	local context = hop.context({
		homeDirectory = "/home/tester",
		runner = function(argv)
			table.insert(commands, argv)
			return { ok = true, exitCode = 0, stdout = "", stderr = "" }
		end,
		loadWorktrees = function()
			return worktrees
		end,
		loadSessions = function()
			return sessions
		end,
		cache = {
			read = function()
				return cached
			end,
			write = function(value)
				cached = value
				table.insert(writes, value)
			end,
		},
		others = {
			read = function()
				return {}
			end,
			write = function() end,
		},
		now = function()
			return 1000
		end,
		activity = function()
			return 0
		end,
	})
	return context, commands, writes
end

test.case("list builds a snapshot from Git without asking GitHub when pullRequests is false", function(assert)
	local context, commands, writes = fakeContext()
	local listing = hop.list(context, { pullRequests = false })
	assert.eq(#listing.snapshot.entries, 2)
	assert.eq(listing.cached, false)
	assert.eq(#listing.others, 0)
	assert.eq(#commands, 0)
	assert.eq(#writes, 0)
end)

test.case("recent filters by agent and skips GitHub when pullRequests is false", function(assert)
	local context, commands = fakeContext()
	local items = hop.recent(context, { agent = "claude", pullRequests = false })
	assert.eq(#items, 1)
	assert.eq(items[1].session.id, "claude-1")
	local worktree = items[1].worktree or error("expected a worktree")
	assert.eq(worktree.branch, "main")
	assert.eq(#commands, 0)
end)

test.case("to returns the matching worktree without opening it", function(assert)
	local context, commands = fakeContext()
	local destination = hop.to(context, "feature/hop")
	assert.eq(#destination.entries, 1)
	assert.eq(tostring(destination.entries[1].worktree.path), tostring(path.parse("/src/widgets-feature")))
	assert.eq(destination.checkout, nil)
	for _, argv in commands do
		assert.neq(argv[1], "code")
	end
end)
