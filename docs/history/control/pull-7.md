# Control PR 7: Add independent SystemVerilog and Python style checks

| Record | Value |
|---|---|
| Author | [abhinavnandwani](https://github.com/abhinavnandwani) |
| Created | 2026-09-30T15:24:10Z |
| Closed | 2026-09-30T15:26:04Z |
| Merged | 2026-09-30T15:26:04Z |
| Original head | [d6fdf659d088](https://github.com/SiliconBadgers/rtl/commit/d6fdf659d0884675a77a5283ca4342073182e85a) |
| Preserved branch | `archive/control/pulls/7/head` |

## Description

Adds standalone source-style tooling that can merge independently of the RTL integration. `make format` applies Verible/Ruff formatting and `make style` checks it. The PR workflow pins Verible v0.0-3946-g851d3ff4 with a verified release checksum and Ruff 0.16.6.

The checker discovers this repository’s source files from style.json and Git, excluding ignored files and submodule contents. It explicitly reports when a scaffold contains no SystemVerilog. No dependency on unmerged RTL paths or CPU/model downloads is introduced.

Validation: make format and make style pass; an intentionally noncompliant temporary SV fixture is rejected. The current main scaffold has no SV inputs; Python tooling checks pass.

Core elaboration, vendor waivers, and hardware simulation remain with the RTL integration PR.

AI assistance: OpenAI Codex. The exact model identifier was unavailable in this execution context.


## Commits

- [d6fdf659d088](https://github.com/SiliconBadgers/rtl/commit/d6fdf659d0884675a77a5283ca4342073182e85a): Add independent Verible and Ruff formatting checks; author abhinavnandwani; 2026-09-30T15:23:35Z.

## Review and discussion

No comments or submitted reviews were recorded.
