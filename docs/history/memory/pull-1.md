# Memory PR 1: Align team scaffolds and check AI setup before commits

| Record | Value |
|---|---|
| Author | [abhinavnandwani](https://github.com/abhinavnandwani) |
| Created | 2026-09-22T23:58:33Z |
| Closed | 2026-09-23T02:52:55Z |
| Merged | 2026-09-23T02:52:55Z |
| Original head | [d459b8731785](https://github.com/SiliconBadgers/rtl/commit/d459b87317858f714cb70756ba6c31f6188e7e05) |
| Preserved branch | `archive/memory/pulls/1/head` |

## Description

The repository needs a usable starting point for the current team assignments and AI attribution configured before contributions are committed. Organizes the memory-controller diagram, interfaces and load-compute-store walkthrough for issue SiliconBadgers/rtl#7.

Adds a per-clone pre-commit guard, a checksum-pinned Git AI setup script, repo-specific AGENTS.md, contribution instructions, PR disclosure checklist and Git AI merge workflow. The guard checks Codex hooks, local prompt storage, daemon readiness and readable attribution; it preserves existing hooks instead of replacing them. Setup must happen before AI edits and be activated in each clone. Local hooks remain bypassable and CI does not prove that unattributed work is human-written.

Validation: 13 commit-guard tests pass locally for this repo, shell syntax and Markdown links checked. The existing cross-repo MAC integration passes (261 vectors and 131,600 independent checks); the planning build succeeds. No Synopsys run is claimed. Live Git AI notes and Codex co-author credit were verified for the new changes. Main protection and admin bypass settings are unchanged.

This provides starting structure and contributor checks; the linked team research/design/implementation issues remain open.


## Commits

- [58b932d32497](https://github.com/SiliconBadgers/rtl/commit/58b932d32497d681c4b5c48a4551cb349f098f7f): Add team starting material and sole code owner; author abhinavnandwani; 2026-09-22T23:57:30Z.
- [deafb33ae2d1](https://github.com/SiliconBadgers/rtl/commit/deafb33ae2d17e4c83963d7175454e4a5cb5b28a): Align team scaffolds and require local AI setup before commits; author abhinavnandwani; 2026-09-23T02:48:05Z.
- [d459b8731785](https://github.com/SiliconBadgers/rtl/commit/d459b87317858f714cb70756ba6c31f6188e7e05): Clarify merge attribution checks and link the preserved register baseline; author abhinavnandwani; 2026-09-23T02:49:57Z.

## Review and discussion

No comments or submitted reviews were recorded.
