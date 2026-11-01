# Hop core

The part of Hop that other Lute tools can use directly, without running the `hop` binary and parsing its JSON. It finds your worktrees and their pull requests, your recent Cursor and Claude Code sessions, and the worktree an expression names, checking a pull request out when needed. It never opens an editor; the [CLI](../hop-cli/README.md) does that.

## Depending on it

Add Hop as a GitHub dependency in your `loom.config.luau`, pinned to a release tag or commit:

```luau
["hop"] = {
	rev = "v0.2.0",
	sourceKind = "github",
	source = "https://github.com/gummy-galaxy/hop",
},
```

Loom installs the whole repository, so point an alias at this package's `src` folder:

```json
"hop": "@pkg/hop@v0.2.0/workspace/hop-core/src"
```

Hop core depends only on Lute's standard library, so it brings no other packages along.

## Usage

```luau
local hop = require("@hop")

local context = hop.context()

local listing = hop.list(context)
for _, entry in listing.snapshot.entries do
	print(entry.worktree.path, entry.pullRequest and entry.pullRequest.url)
end

local sessions = hop.recent(context, { limit = 10 })

local destination = hop.to(context, "flipbook#482")
print(destination.entries[1].worktree.path)
```

- `hop.context(options?)` reads your machine by default: Git, `gh`, the Cursor and Claude Code data folders, and Hop's cache in `~/.hop`. Pass `runner`, `homeDirectory`, `loadWorktrees`, `loadSessions`, `cache`, `others`, `now`, or `activity` to replace any of them.
- `hop.list(context, { refresh?, pullRequests? })` returns the cached or rebuilt snapshot of your worktrees and their pull requests, your open pull requests without a worktree, and others' pull requests Hop checked out.
- `hop.recent(context, { limit?, repository?, agent?, pullRequests? })` returns your recent sessions, each with its worktree and pull request.
- `hop.to(context, expression)` returns the worktrees an expression matches. When it had to check a pull request out, `checkout` says which one and whether the worktree is new. It errors when nothing matches.

`src/init.luau` is the public entry point. The other modules are internal and can change between releases; the CLI uses them because it ships from the same commit.
