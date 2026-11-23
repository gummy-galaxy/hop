---
bump: minor
category: Features
---

`hop clean --merged` removes the worktrees Hop checked out for pull requests that have merged, and `hop clean --all` removes all of them. Only Hop's own `<folder>-pr-<number>` checkouts and the ones under `~/.hop/cache` are removed, and a merged checkout's branch is deleted only when nothing on it missed the merge. In VS Code, **Hop: Remove Worktrees for Merged Pull Requests** and **Hop: Remove All Pull Request Worktrees** do the same after asking.
