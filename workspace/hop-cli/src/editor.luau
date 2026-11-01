local platform = require("@std/system/platform")

local defaultRun = require("@hop/command")
local types = require("@hop/types")

export type System = "macos" | "windows" | "linux"

local EXTENSION_ID = "vocksel.hop"
local NATIVE: System = if platform.win32 then "windows" elseif platform.macos then "macos" else "linux"

-- Windows installs `code` and `agent` as batch scripts, which only `cmd` can start.
local function launcher(argv: { string }, system: System): { string }
	if system == "windows" then
		return { "cmd", "/c", table.unpack(argv) }
	end
	return argv
end

-- Windows hands the URI to its protocol handler directly, so `cmd` never parses it.
local function uriOpener(uri: string, system: System): { string }
	if system == "macos" then
		return { "open", uri }
	elseif system == "windows" then
		return { "rundll32", "url.dll,FileProtocolHandler", uri }
	end
	return { "xdg-open", uri }
end

local function invoke(argv: { string }, runner: types.CommandRunner?)
	local run = runner or defaultRun
	local ok, result = pcall(run, argv)
	if not ok then
		error(`unable to run {argv[1]}: {result}`)
	end
	if not result.ok then
		error(`{argv[1]} failed: {result.stderr}`)
	end
end

-- Asks VS Code rather than inspecting its extensions folder, which can keep uninstalled
-- extensions until VS Code cleans up. VS Code's CLI cannot report whether an extension is disabled.
local function extensionInstalled(runner: types.CommandRunner?, system: System): boolean
	local run = runner or defaultRun
	local ok, result = pcall(run, launcher({ "code", "--list-extensions" }, system))
	if not ok or not result.ok then
		return false
	end
	for line in result.stdout:gmatch("[^\r\n]+") do
		if line:lower() == EXTENSION_ID then
			return true
		end
	end
	return false
end

local function encode(value: string): string
	return (value:gsub("[^%w%-%._~/]", function(character)
		return string.format("%%%02X", character:byte())
	end))
end

local function handoffUri(directory: string): string
	return `vscode://vocksel.hop/to?path={encode(directory)}`
end

-- With the Hop extension installed, the most recently focused VS Code window switches to
-- the folder in place. Otherwise VS Code opens it the usual way.
local function open(directory: string, runner: types.CommandRunner?, system: System?)
	local resolved = system or NATIVE
	if extensionInstalled(runner, resolved) then
		invoke(uriOpener(handoffUri(directory), resolved), runner)
		return
	end
	invoke(launcher({ "code", directory }, resolved), runner)
end

local function resume(directory: string, sessionId: string, runner: types.CommandRunner?, system: System?)
	invoke(launcher({ "agent", "--workspace", directory, "--resume", sessionId }, system or NATIVE), runner)
end

return table.freeze({
	handoffUri = handoffUri,
	open = open,
	resume = resume,
})
