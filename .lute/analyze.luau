local FlipbookBatteries = require("@flipbook-batteries")

local run = FlipbookBatteries.run

-- Lute files to lint and type-check. `workspace/hop-cli` is listed file by file
-- because it also holds the packages `lute run install` copies in.
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
