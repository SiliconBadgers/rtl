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
