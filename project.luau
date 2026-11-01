local path = require("@std/path")

-- Where each package lives. Lute scripts run from the repository root, so these
-- resolve against it.
local CLI_PATH = path.resolve("workspace/hop-cli")

return {
	CORE_PATH = path.resolve("workspace/hop-core"),
	CLI_PATH = CLI_PATH,
	BUILD_PATH = path.join(CLI_PATH, "build"),
	BUILD_OUTPUT = path.join(CLI_PATH, "build", "hop"),
}
