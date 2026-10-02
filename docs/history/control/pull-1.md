# Control PR 1: Align team scaffolds and check AI setup before commits

| Record | Value |
|---|---|
| Author | [abhinavnandwani](https://github.com/abhinavnandwani) |
| Created | 2026-09-22T23:58:40Z |
| Closed | 2026-09-23T02:52:51Z |
| Merged | 2026-09-23T02:52:51Z |
| Original head | [be0ad5fbbdfd](https://github.com/SiliconBadgers/rtl/commit/be0ad5fbbdfda9ff5568ef1ce205a54d070d106e) |
| Preserved branch | `archive/control/pulls/1/head` |

## Description

The repository needs a usable starting point for the current team assignments and AI attribution configured before contributions are committed. Organizes the controller diagram and command walkthrough for issue SiliconBadgers/rtl#6, with shared MMIO/descriptor work explicitly owned in architecture#3.

Adds a per-clone pre-commit guard, a checksum-pinned Git AI setup script, repo-specific AGENTS.md, contribution instructions, PR disclosure checklist and Git AI merge workflow. The guard checks Codex hooks, local prompt storage, daemon readiness and readable attribution; it preserves existing hooks instead of replacing them. Setup must happen before AI edits and be activated in each clone. Local hooks remain bypassable and CI does not prove that unattributed work is human-written.

Validation: 13 commit-guard tests pass locally for this repo, shell syntax and Markdown links checked. The existing cross-repo MAC integration passes (261 vectors and 131,600 independent checks); the planning build succeeds. No Synopsys run is claimed. Live Git AI notes and Codex co-author credit were verified for the new changes. Main protection and admin bypass settings are unchanged.

This provides starting structure and contributor checks; the linked team research/design/implementation issues remain open.


## Commits

- [f63ddfc99595](https://github.com/SiliconBadgers/rtl/commit/f63ddfc99595838e8454a9b72fb1e483209b290a): Add team starting material and sole code owner; author abhinavnandwani; 2026-09-22T23:57:31Z.
- [48123776c00c](https://github.com/SiliconBadgers/rtl/commit/48123776c00cd12b1b4a7692ece4a9e1d76bb4c5): Align team scaffolds and require local AI setup before commits; author abhinavnandwani; 2026-09-23T02:48:06Z.
- [be0ad5fbbdfd](https://github.com/SiliconBadgers/rtl/commit/be0ad5fbbdfda9ff5568ef1ce205a54d070d106e): Clarify merge attribution checks and link the preserved register baseline; author abhinavnandwani; 2026-09-23T02:49:58Z.

## Review and discussion

No comments or submitted reviews were recorded.
