local fs = require("@std/fs")
local path = require("@std/path")
local process = require("@std/process")
local project = require("@repo/project")

local packagesDir = path.join(project.CLI_PATH, "packages")
local storeDir = path.join(process.homedir(), ".loom", "store")

if not fs.exists(packagesDir) then
	fs.createDirectory(packagesDir, { makeParents = true })
end

local installed = process.run({ "lute", "pkg", "install" }, { stdio = "inherit", cwd = tostring(project.CLI_PATH) })
assert(installed.ok, `lute pkg install failed ({installed.exitcode})`)

local lock = require("@repo/workspace/hop-cli/loom.lock")

fs.removeDirectory(packagesDir, { recursive = true })
fs.createDirectory(packagesDir)

-- Copies in Lute rather than with `cp`, which Windows lacks.
local function copyDirectory(source: path.Path, destination: path.Path)
	fs.createDirectory(destination, { makeParents = true })

	for _, entry in fs.listDirectory(source) do
		local from, to = path.join(source, entry.name), path.join(destination, entry.name)

		if entry.type == "dir" then
			copyDirectory(from, to)
		elseif entry.type == "file" then
			fs.copy(from, to)
		end
	end
end

for packageId in lock.packages :: { [string]: unknown } do
	copyDirectory(path.join(storeDir, packageId), path.join(packagesDir, packageId))
end
