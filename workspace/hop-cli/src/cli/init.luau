local cli = require("@batteries/cli")
local io = require("@std/io")
local json = require("@std/json")
local path = require("@std/path")
local process = require("@std/process")

local cache = require("@hop/cache")
local editor = require("@root/editor")
local hop = require("@hop")
local others = require("@hop/others")
local render = require("@root/render")
local resolve = require("@hop/core/resolve")
local snapshot = require("@hop/core/snapshot")
local types = require("@hop/types")

type RecentItem = hop.RecentItem

export type Dependencies = {
	runner: types.CommandRunner?,
	input: (() -> string?)?,
	write: ((string) -> ())?,
	homeDirectory: path.Pathlike?,
	loadSessions: (() -> { types.Session })?,
	loadWorktrees: (() -> { types.Worktree })?,
	cache: cache.Cache?,
	others: others.Store?,
	now: (() -> number)?,
	activity: resolve.Activity?,
	system: editor.System?,
}

type Resolved = {
	runner: types.CommandRunner,
	input: () -> string?,
	write: (string) -> (),
	homeDirectory: string,
	loadWorktrees: () -> { types.Worktree },
	loadSessions: () -> { types.Session },
	cache: cache.Cache,
	others: others.Store,
	now: () -> number,
	activity: resolve.Activity,
	system: editor.System?,
}

type RecentOptions = {
	limit: number,
	repository: string?,
	agent: ("cursor" | "claude")?,
	json: boolean,
}

type ListOptions = {
	refresh: boolean,
	pullRequests: boolean,
	json: boolean,
}

local SUMMARY = "hop — jump from agent sessions and pull requests to local worktrees"

local EXPRESSIONS = [[
Expressions:
  owner/repo#123, repo#123, #123, or a PR URL
  your open PR without a worktree is checked out beside your clone as <folder>-pr-<number>
  anyone else's is checked out under ~/.hop/cache, cloning the repository there if needed
  otherwise words that each match a branch, repository, folder name, PR title, or repo#123 of your work
  bare numbers are words; only references reach others' work
  `default` matches a repository's default branch, as in `hop flipbook default`
  A repository's default-branch checkout is listed first, then the most recently changed]]

local COMMAND_HELP: { [string]: string } = {
	to = "Open the worktree matching <expr> in VS Code",
	list = "List worktrees with their pull requests",
	recent = "List recent Cursor and Claude Code sessions",
	cursor = "Resume a Cursor session in its workspace",
	help = "Show help for Hop or one of its commands",
}

type Parsers = {
	root: cli.Parser,
	commands: { [string]: cli.Parser },
}

local function addHelpFlag(parser: cli.Parser)
	parser:add("help", "flag", { help = "Show this help", aliases = { "h" } })
end

local function createParsers(): Parsers
	local root = cli.parser()
	addHelpFlag(root)

	local commands: { [string]: cli.Parser } = {}
	local function command(name: string): cli.Parser
		local parser = root:subcommand(name, { help = COMMAND_HELP[name] })
		addHelpFlag(parser)
		commands[name] = parser
		return parser
	end

	command("to"):add("expr", "variadic", { help = "Expression to match against worktrees and pull requests" })

	local list = command("list")
	list:add("refresh", "flag", { help = "Rebuild the cached list from Git and GitHub" })
	list:add("no-pr", "flag", { help = "Skip GitHub pull request lookup" })
	list:add("json", "flag", { help = "Print JSON" })

	local recent = command("recent")
	recent:add("limit", "option", { help = "Maximum number of sessions to show (default 20)", default = "20" })
	recent:add("repo", "option", { help = "Only show sessions for OWNER/REPO" })
	recent:add("agent", "option", { help = "Only show sessions from cursor or claude" })
	recent:add("json", "flag", { help = "Print JSON" })

	command("cursor"):add("query", "positional", { help = "Session number, title, id, or branch" })

	command("help"):add("command", "positional", { help = "Command to describe" })

	return { root = root, commands = commands }
end

-- A leading word that is not a command is an expression for `hop to`.
local function withDefaultCommand(args: { string }): { string }
	local first = args[1]
	if first == nil or first:sub(1, 1) == "-" or COMMAND_HELP[first] then
		return args
	end
	return { "to", table.unpack(args) }
end

local function rootHelp(parser: cli.Parser): string
	return table.concat({
		SUMMARY,
		"",
		parser:usage("hop"),
		"       hop <expr>  Same as `hop to <expr>`",
		"",
		parser:help(),
		"",
		EXPRESSIONS,
	}, "\n")
end

local function commandHelp(name: string, parser: cli.Parser): string
	return `{COMMAND_HELP[name]}\n\n{parser:usage(`hop {name}`)}\n\n{parser:help()}`
end

local function recentOptions(parser: cli.Parser): RecentOptions
	local limit = tonumber(parser:get("limit"))
	assert(limit and limit >= 0 and limit % 1 == 0, "--limit must be a non-negative integer")
	local agent = parser:get("agent")
	assert(agent == nil or agent == "cursor" or agent == "claude", "--agent must be cursor or claude")
	return {
		limit = limit,
		repository = parser:get("repo"),
		agent = agent,
		json = parser:has("json"),
	}
end

local function listOptions(parser: cli.Parser): ListOptions
	return {
		refresh = parser:has("refresh"),
		pullRequests = not parser:has("no-pr"),
		json = parser:has("json"),
	}
end

local function dependencies(options: Dependencies?): Resolved
	local resolved: Dependencies = options or {}
	local context = hop.context(resolved)
	return {
		runner = context.runner,
		input = resolved.input or function()
			return io.input()
		end,
		write = resolved.write or print,
		homeDirectory = context.homeDirectory,
		loadWorktrees = context.loadWorktrees,
		loadSessions = context.loadSessions,
		cache = context.cache,
		others = context.others,
		now = context.now,
		activity = context.activity,
		system = resolved.system,
	}
end

local function itemJson(item: RecentItem): json.Object
	local session = item.session
	local worktree = item.worktree
	return {
		agent = session.agent,
		id = session.id,
		title = session.title,
		directory = if worktree then tostring(worktree.path) else session.directory,
		branch = if worktree then worktree.branch else session.branchAtSessionTime,
		repository = if worktree then worktree.repository else nil,
		pullRequest = if item.pullRequest then item.pullRequest.number else nil,
		pullRequestUrl = if item.pullRequest then item.pullRequest.url else nil,
		updatedAt = session.updatedAt,
		needsAttention = session.needsAttention,
		filesChanged = session.filesChanged,
	}
end

local function itemWorktree(item: RecentItem): types.Worktree?
	if item.worktree then
		return item.worktree
	end
	if item.session.directory then
		return {
			path = path.parse(item.session.directory),
			branch = item.session.branchAtSessionTime,
			repository = nil,
			primary = false,
		}
	end
	return nil
end

local function selectItem(
	items: { RecentItem },
	query: string?,
	input: () -> string?,
	write: (string) -> ()
): RecentItem?
	if query == nil then
		return render.choose(items, input, write)
	end
	local index = tonumber(query)
	if index and index % 1 == 0 then
		return items[index]
	end
	local normalized = query:lower()
	local matches: { RecentItem } = {}
	for _, item in items do
		local title = (item.session.title or ""):lower()
		local id = item.session.id:lower()
		local branch = (item.session.branchAtSessionTime or ""):lower()
		if title:find(normalized, 1, true) or id:find(normalized, 1, true) or branch:find(normalized, 1, true) then
			table.insert(matches, item)
		end
	end
	return render.choose(matches, input, write)
end

local function age(seconds: number): string
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return `{seconds // 60}m ago`
	elseif seconds < 86400 then
		return `{seconds // 3600}h ago`
	end
	return `{seconds // 86400}d ago`
end

local function list(deps: Resolved, options: ListOptions)
	local listing = hop.list(deps, { refresh = options.refresh, pullRequests = options.pullRequests })
	local value, cached = listing.snapshot, listing.cached
	local otherEntries = listing.others
	if options.json then
		local object = snapshot.toJson(value, deps.activity)
		object.others = snapshot.entriesToJson(otherEntries, deps.activity)
		deps.write(json.serialize(object, true))
		return
	end
	local sections: { string } = {}
	if #value.entries > 0 then
		table.insert(
			sections,
			render.numberedWith(value.entries, function(entry)
				return render.entryLabel(entry, deps.homeDirectory)
			end)
		)
	else
		table.insert(sections, "No worktrees found.")
	end
	if #value.pullRequests > 0 then
		table.insert(
			sections,
			"Open pull requests without a local worktree:\n"
				.. render.numberedWith(value.pullRequests, render.pullRequestLabel)
		)
	end
	if #otherEntries > 0 then
		table.insert(sections, "Others' pull requests:\n" .. render.numberedWith(otherEntries, function(entry)
			return render.entryLabel(entry, deps.homeDirectory)
		end))
	end
	if cached then
		table.insert(sections, `Cached {age(deps.now() - value.generatedAt)}; run \`hop list --refresh\` to update.`)
	end
	deps.write(table.concat(sections, "\n\n"))
end

local function openChoice(deps: Resolved, entries: { snapshot.Entry })
	local selected = render.chooseWith(entries, function(entry)
		return render.entryLabel(entry, deps.homeDirectory)
	end, deps.input, deps.write)
	assert(selected, "no worktree selected")
	editor.open(tostring(selected.worktree.path), deps.runner, deps.system)
end

local function to(deps: Resolved, args: { string })
	local text = table.concat(args, " ")
	assert(text:match("%S"), "usage: hop to <expr>")
	local destination = hop.to(deps, text)
	local checkout = destination.checkout
	if checkout == nil then
		openChoice(deps, destination.entries)
		return
	end
	local worktreePath = tostring(destination.entries[1].worktree.path)
	if checkout.created then
		deps.write(`Checked out {checkout.target.repository}#{checkout.target.number} in {worktreePath}`)
	end
	editor.open(worktreePath, deps.runner, deps.system)
end

local function execute(args: { string }, options: Dependencies?)
	local parsers = createParsers()
	parsers.root:parse(withDefaultCommand(args))
	local deps = dependencies(options)

	local command, parser = parsers.root:selected()
	if command == "help" and parser then
		local topic = parser:get("command")
		if topic then
			local topicParser = parsers.commands[topic]
			assert(topicParser, `unknown command: {topic}`)
			deps.write(commandHelp(topic, topicParser))
			return
		end
	end
	if command == nil or parser == nil or command == "help" or parsers.root:has("help") then
		deps.write(rootHelp(parsers.root))
		return
	end
	if parser:has("help") then
		deps.write(commandHelp(command, parser))
		return
	end

	if command == "to" then
		to(deps, parser:variadics())
	elseif command == "list" then
		list(deps, listOptions(parser))
	elseif command == "recent" then
		local selectedOptions = recentOptions(parser)
		local items = hop.recent(deps, {
			limit = selectedOptions.limit,
			repository = selectedOptions.repository,
			agent = selectedOptions.agent,
		})
		if selectedOptions.json then
			local values: { json.Value } = {}
			for _, item in items do
				table.insert(values, itemJson(item))
			end
			deps.write(json.serialize(values, true))
		else
			deps.write(render.numbered(items))
		end
	elseif command == "cursor" then
		local cursorItems = hop.recent(deps, { agent = "cursor", pullRequests = false })
		local selected = selectItem(cursorItems, parser:get("query"), deps.input, deps.write)
		assert(selected, "no matching Cursor session found")
		local target = assert(itemWorktree(selected), "Cursor session has no workspace")
		editor.resume(tostring(target.path), selected.session.id, deps.runner, deps.system)
	end
end

-- Lute passes the program path as the first argument.
local function run(argv: { string })
	local ok, message = pcall(execute, { table.unpack(argv, 2) }, nil)
	if not ok then
		local text = tostring(message):gsub("^[^\n]-:%d+: ", "", 1)
		print(`Error: {text}`)
		process.exit(1)
	end
end

return table.freeze({
	execute = execute,
	run = run,
})
