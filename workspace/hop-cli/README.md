# Hop CLI

`hop`, written in Luau and compiled with [Lute](https://github.com/luau-lang/lute). It parses commands, prints results, and opens worktrees in VS Code. Finding worktrees, pull requests, and sessions is left to [`hop-core`](../hop-core/README.md), which it requires as `@hop`. The [repository README](../../README.md) covers the commands and how to build them.

`src/cli/init.luau` holds the commands, `src/render.luau` formats their output, and `src/editor.luau` is the only module that runs `code` or `agent`. Each spec sits beside its module as `<module>.spec.luau`.
