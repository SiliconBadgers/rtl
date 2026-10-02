# Control PR 4: Remove AI setup requirements for contributors

| Record | Value |
|---|---|
| Author | [abhinavnandwani](https://github.com/abhinavnandwani) |
| Created | 2026-09-24T16:20:11Z |
| Closed | 2026-09-24T16:21:33Z |
| Merged | 2026-09-24T16:21:33Z |
| Original head | [ed7642f58808](https://github.com/SiliconBadgers/rtl/commit/ed7642f588089b6e0fb895fc85f89fe287fb6fea) |
| Preserved branch | `archive/control/pulls/4/head` |

## Description

Contributors can edit and commit without installing Codex or Git AI. Removes the repository commit guard, installation/checking scripts, attribution workflows, model-reporting form, and setup requirements from the contributor docs.

AGENTS.md keeps a short instruction for AI agents to disclose their tool and exact model when available in the PR or change summary. The normal contribution workflow, CODEOWNERS, technical sources, and build/test commands are unchanged.

Validation: reviewed the staged file list and diff, checked edited local documentation links, and verified that the deleted setup files have no remaining contribution instructions pointing to them. No design or runtime code changed.

AI assistance: Codex. The exact model ID was not available in this turn's tool metadata.


## Commits

- [ed7642f58808](https://github.com/SiliconBadgers/rtl/commit/ed7642f588089b6e0fb895fc85f89fe287fb6fea): Remove AI setup requirements for contributors; author abhinavnandwani; 2026-09-24T16:20:07Z.

## Review and discussion

No comments or submitted reviews were recorded.
