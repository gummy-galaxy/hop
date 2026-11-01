local FlipbookBatteries = require("@flipbook-batteries")

local run = FlipbookBatteries.run

-- Lists each package's files rather than the whole folder, so the CLI's
-- installed `packages/` stay out.
local sources = {
	"workspace/hop-core/src",
	"workspace/hop-core/loom.config.luau",
	"workspace/hop-cli/src",
	"workspace/hop-cli/cli.luau",
	"workspace/hop-cli/loom.config.luau",
	".lute",
	"project.luau",
}

run("stylua", { "--check", "." })
run("lute", { "lint", table.unpack(sources) })
run("lute", { "check", table.unpack(sources) })
