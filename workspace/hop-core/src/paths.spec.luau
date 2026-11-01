local test = require("@std/test")

local paths = require("@root/paths")

local posix = paths.forPlatform(false)
local windows = paths.forPlatform(true)

test.case("paths match through trailing slashes and dot segments", function(assert)
	assert.eq(posix.same("/src/hop/", "/src/./hop"), true)
	assert.eq(posix.same("/src/hop", "/src/hop-pr-1"), false)
end)

test.case("paths beneath a parent keep their remaining parts", function(assert)
	local rest = posix.below("/home/me/.hop/cache", "/home/me/.hop/cache/worktrees/hop-pr-1")
	assert.eq(rest and table.concat(rest, "/"), "worktrees/hop-pr-1")
	assert.eq(posix.below("/home/me/.hop/cache", "/home/me/.hop/cached"), nil)
	assert.eq(posix.below("/home/me/.hop/cache", "/home/me"), nil)
end)

test.case("posix paths compare case-sensitively", function(assert)
	assert.eq(posix.same("/src/Hop", "/src/hop"), false)
end)

test.case("windows paths match across separators and case", function(assert)
	assert.eq(windows.same("C:/Users/Me/src/hop", "c:\\users\\me\\src\\hop\\"), true)
	assert.eq(windows.same("C:\\src\\hop", "D:\\src\\hop"), false)

	local rest = windows.below("C:\\Users\\me", "C:/Users/me/src/Hop")
	assert.eq(rest and table.concat(rest, "\\"), "src\\Hop")
end)

test.case("basename reads the last part on either separator", function(assert)
	assert.eq(posix.basename("/src/hop/"), "hop")
	assert.eq(windows.basename("C:\\src\\hop-pr-1"), "hop-pr-1")
	assert.eq(windows.basename("C:/src/hop"), "hop")
end)
