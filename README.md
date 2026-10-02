# Development moved to SiliconBadgers RTL

New memory work belongs in [SiliconBadgers/rtl](https://github.com/SiliconBadgers/rtl).
Use the [current memory guide](https://github.com/SiliconBadgers/rtl/blob/main/docs/memory/START-HERE.md)
and [assignment #7](https://github.com/SiliconBadgers/rtl/issues/7).
SoC composition remains in [SiliconBadgers/soc](https://github.com/SiliconBadgers/soc).

The original commits are preserved in the combined RTL history. This repository
retains the original pull requests, reviews and branches for reference.
The overview below describes the former standalone repository.

---

# Memory Control

Design the memory controller and explain data movement, outstanding requests, buffer ownership and safe reuse.

## Start here

1. Read [the current assignment and artifact locations](docs/START-HERE.md).
2. Work on a branch and open a PR for `@abhinavnandwani` using
   [CONTRIBUTING.md](CONTRIBUTING.md). Main requires a code-owner approval;
   admins can bypass.

## Current issues

- [Memory-controller diagram and data-flow walkthrough](https://github.com/SiliconBadgers/rtl-memory/issues/2)

## Repository structure

| Location | Purpose |
|---|---|
| [docs/controller/](docs/controller/README.md) | Memory-controller diagram, block/interface descriptions, load-compute-store traces and open assumptions for rtl-memory#2. Include editable source and a preview for draw.io. |

## Current material and scope

The repo provides design scaffolding. A controller implementation and its verification results are still to be developed.

[Shared diagram](https://github.com/SiliconBadgers/architecture/blob/main/docs/accelerator-diagram.md) · [Software evidence](https://github.com/SiliconBadgers/software/tree/main/experiments/llama-cpp/2026-09-22)

[CHARTER.md](CHARTER.md) and [OBJECTIVES.md](OBJECTIVES.md) describe the
longer-term purpose. Current issues and the starting guide specify the work
assigned now. [SETUP.md](SETUP.md) describes existing example commands and scope.
