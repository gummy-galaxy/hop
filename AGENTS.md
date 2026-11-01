# Hop agent guide

Hop is a strict Luau CLI running on Lute and compiling to a native executable.

## Setup and validation

Run these commands before completing a change:

```sh
rokit install
lute run install
lute setup
lute run analyze
lute test
lute run build
```

## Conventions

- Keep production code in each package's `src/` under `workspace/` and colocate tests as `*.spec.luau`.
- Keep `workspace/hop-core` free of editor code and of package dependencies. Loom installs a GitHub dependency's own dependencies only from the repository root's manifest, so anything the core required beyond Lute's standard library would be missing for tools that depend on it.
- Expose what other tools need from `workspace/hop-core/src/init.luau`; the CLI requires the core as `@hop`.
- Preserve strict types and use the aliases declared in each package's `.luaurc`.
- Name a required module after the module itself, such as `local cli = require("@batteries/cli")`, without prefixing the package.
- Route every external command through the `CommandRunner` seam in `workspace/hop-core/src/types.luau`.
- Keep every `code` and `agent` invocation in `workspace/hop-cli/src/editor.luau`.
- Treat missing Cursor, Claude Code, or local tool data as provider degradation rather than a failure of unrelated commands.
- Never follow symlinks or remove the repository and depth bounds from discovery.
- Do not add machine-specific absolute paths.
- Add a `.changes/` entry for user-facing changes.
