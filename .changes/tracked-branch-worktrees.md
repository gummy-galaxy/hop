---
bump: patch
category: Fixes
---

Opening a PR in **Hop: Go** or with `hop <PR URL>` now reuses a worktree whose local branch has a different name but tracks the PR's branch, such as an agent worktree on `agent/fix-1a2b3c` pushed as `agent/fix`, instead of checking out a new `<folder>-pr-<number>` worktree. These worktrees also show their PR in `hop list` and **Hop: Go**.
