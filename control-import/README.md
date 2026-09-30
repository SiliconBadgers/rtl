# Top-Level Control

Design command receipt, validation, dispatch, coordination and completion. This team works in rtl-control for controller internals and architecture for the shared register/descriptor contract.

## Start here

1. Read [the current assignment and artifact locations](docs/START-HERE.md).
2. Work on a branch and open a PR for `@abhinavnandwani` using
   [CONTRIBUTING.md](CONTRIBUTING.md). Main requires a code-owner approval;
   admins can bypass.

## Current issues

- [Controller block diagram and command flow](https://github.com/SiliconBadgers/rtl-control/issues/2)
- [Shared MMIO/descriptor proposal in architecture](https://github.com/SiliconBadgers/architecture/issues/3)

## Repository structure

| Location | Purpose |
|---|---|
| [docs/controller/](docs/controller/README.md) | Controller diagram, interfaces, state/control flow and command walkthroughs for rtl-control#2. Keep editable source, plus SVG/PNG preview for draw.io. Link the architecture register proposal instead of copying the maps. |

## Current material and scope

This repo has design scaffolding, not a runnable accelerator controller. The one-command slide proposal is a starting point to evaluate. This work does not design a CPU instruction decoder.

[Shared diagram](https://github.com/SiliconBadgers/architecture/blob/main/docs/accelerator-diagram.md) · [Software evidence](https://github.com/SiliconBadgers/software/tree/main/experiments/llama-cpp/2026-09-22)

[CHARTER.md](CHARTER.md) and [OBJECTIVES.md](OBJECTIVES.md) describe the
longer-term purpose. Current issues and the starting guide specify the work
assigned now. [SETUP.md](SETUP.md) describes existing example commands and scope.
