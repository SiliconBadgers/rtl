# Top-Level Control: current work

Design command receipt, validation, dispatch, coordination and completion. This team works in rtl-control for controller internals and architecture for the shared register/descriptor contract.

## Assignment

- [Controller block diagram and command flow](https://github.com/SiliconBadgers/rtl-control/issues/2)
- [Shared MMIO/descriptor proposal in architecture](https://github.com/SiliconBadgers/architecture/issues/3)

1. Expand the central diagram into a Mermaid or editable draw.io controller diagram with block responsibilities and interfaces.
2. Walk through a representative command from acceptance through compute/memory completion and status reporting. Explain readiness, stalls/backpressure, outstanding work, errors and reset/quiescence.
3. Review the two slide maps and trace llama.cpp operations, metadata and synchronization. Propose the actual MMIO map and command descriptor in architecture#3; explain field changes and command examples.
4. Keep exact unit details and latencies explicit as assumptions. Exchange interfaces with Memory and each Compute team and give Verification concrete behavior to test.

## Starting evidence

- [Central diagram](https://github.com/SiliconBadgers/architecture/blob/main/docs/accelerator-diagram.md)
- [Recorded Software profiling package](https://github.com/SiliconBadgers/software/tree/main/experiments/llama-cpp/2026-09-22)
- [Slide register maps](https://github.com/SiliconBadgers/architecture/blob/main/docs/register-maps.md) (preserved slide baseline from [architecture PR #2](https://github.com/SiliconBadgers/architecture/pull/2))

## Artifact locations

| Location | What belongs here |
|---|---|
| [docs/controller/](../docs/controller/README.md) | Controller diagram, interfaces, state/control flow and command walkthroughs for rtl-control#2. Keep editable source, plus SVG/PNG preview for draw.io. Link the architecture register proposal instead of copying the maps. |

## What runs today

This repo has design scaffolding, not a runnable accelerator controller. The one-command slide proposal is a starting point to evaluate. This work does not design a CPU instruction decoder.

These folders organize the work; they do not complete the issues. Use the
existing evidence now and publish useful intermediate results. Arrange a team
meeting this week to divide the work and agree on next steps.

Follow [CONTRIBUTING.md](../CONTRIBUTING.md) before editing or committing.
