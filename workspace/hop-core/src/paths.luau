local path = require("@std/path")
local platform = require("@std/system/platform")

-- Paths are compared by their normalized parts rather than as strings. Git reports Windows paths
-- with `/` while Lute formats them with `\`, and Windows ignores case.
export type Paths = {
	read separator: string,
	read same: (path.Pathlike, path.Pathlike) -> boolean,
	read below: (path.Pathlike, path.Pathlike) -> { string }?,
	read basename: (path.Pathlike) -> string,
}

type Split = { drive: string?, parts: { string }, keys: { string } }

local function forPlatform(windows: boolean): Paths
	local function split(value: path.Pathlike): Split
		local text = tostring(value)

		if not windows then
			local parts = path.posix.normalize(text).parts
			return { drive = nil, parts = parts, keys = parts }
		end

		local normalized = path.win32.normalize(text)
		local keys = {}
		for _, part in normalized.parts do
			table.insert(keys, part:lower())
		end
		return {
			drive = if normalized.drive then normalized.drive:lower() else nil,
			parts = normalized.parts,
			keys = keys,
		}
	end

	-- The parts of `child` beneath `parent`: empty for the same path, or nil when `child` is elsewhere.
	local function below(parent: path.Pathlike, child: path.Pathlike): { string }?
		local outer, inner = split(parent), split(child)
		if outer.drive ~= inner.drive or #inner.keys < #outer.keys then
			return nil
		end
		for index, key in outer.keys do
			if inner.keys[index] ~= key then
				return nil
			end
		end
		return table.move(inner.parts, #outer.parts + 1, #inner.parts, 1, {})
	end

	local function same(left: path.Pathlike, right: path.Pathlike): boolean
		local rest = below(left, right)
		return rest ~= nil and #rest == 0
	end

	local function basename(value: path.Pathlike): string
		local parts = split(value).parts
		return parts[#parts] or tostring(value)
	end

	return table.freeze({
		separator = if windows then "\\" else "/",
		same = same,
		below = below,
		basename = basename,
	})
end

local native = forPlatform(platform.win32)

return table.freeze({
	separator = native.separator,
	same = native.same,
	below = native.below,
	basename = native.basename,
	forPlatform = forPlatform,
})
