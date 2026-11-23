---
bump: patch
---

Pull request checkouts on a `pr-<number>` branch now load in the GitHub Pull Requests extension. Hop records each one's pull request in `branch.pr-<number>.github-pr-owner-number` and, when the head branch lives in the same repository, tracks it as the upstream. `hop to` and **Hop: Go** link older `pr-<number>` checkouts the next time they open them.
