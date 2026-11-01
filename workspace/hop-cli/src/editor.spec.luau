local test = require("@std/test")

local editor = require("@root/editor")
local types = require("@hop/types")

local function fakeCode(extensions: string, commands: { { string } }): types.CommandRunner
	return function(argv)
		table.insert(commands, argv)
		if table.find(argv, "code") and table.find(argv, "--list-extensions") then
			return { ok = true, exitCode = 0, stdout = extensions, stderr = "" }
		end
		return { ok = true, exitCode = 0, stdout = "", stderr = "" }
	end
end

test.case("editor hands off to the Hop extension when VS Code lists it", function(assert)
	local commands: { { string } } = {}
	editor.open("/src/my widgets", fakeCode("ms-python.python\nVocksel.hop\n", commands), "macos")
	local last = commands[#commands]
	assert.eq(last[1], "open")
	assert.eq(last[2], "vscode://vocksel.hop/to?path=/src/my%20widgets")
end)

test.case("editor falls back to code without the extension", function(assert)
	local commands: { { string } } = {}
	editor.open("/src/widgets", fakeCode("vocksel.hop-other\n", commands), "macos")
	local last = commands[#commands]
	assert.eq(last[1], "code")
	assert.eq(last[2], "/src/widgets")
end)

test.case("editor falls back to code when VS Code cannot list extensions", function(assert)
	local commands: { { string } } = {}
	editor.open("/src/widgets", function(argv)
		table.insert(commands, argv)
		local listing = argv[2] == "--list-extensions"
		return { ok = not listing, exitCode = if listing then 1 else 0, stdout = "", stderr = "" }
	end, "macos")
	local last = commands[#commands]
	assert.eq(last[1], "code")
	assert.eq(last[2], "/src/widgets")
end)

test.case("editor starts VS Code's scripts through cmd on Windows", function(assert)
	local commands: { { string } } = {}
	editor.open("C:\\src\\widgets", fakeCode("", commands), "windows")
	assert.eq(table.concat(commands[1], " "), "cmd /c code --list-extensions")
	assert.eq(table.concat(commands[2], " "), "cmd /c code C:\\src\\widgets")
end)

test.case("editor opens the handoff URI with each platform's handler", function(assert)
	local windows: { { string } } = {}
	editor.open("C:\\src\\widgets", fakeCode("vocksel.hop\n", windows), "windows")
	local last = windows[#windows]
	assert.eq(last[1], "rundll32")
	assert.eq(last[2], "url.dll,FileProtocolHandler")
	assert.eq(last[3], editor.handoffUri("C:\\src\\widgets"))

	local linux: { { string } } = {}
	editor.open("/src/widgets", fakeCode("vocksel.hop\n", linux), "linux")
	assert.eq(linux[#linux][1], "xdg-open")
end)

test.case("editor resumes Cursor sessions through cmd on Windows", function(assert)
	local commands: { { string } } = {}
	editor.resume("C:\\src\\widgets", "composer-1", fakeCode("", commands), "windows")
	assert.eq(table.concat(commands[1], " "), "cmd /c agent --workspace C:\\src\\widgets --resume composer-1")
end)
