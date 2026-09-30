# Memory Control: current work

Design the memory controller and explain data movement, outstanding requests, buffer ownership and safe reuse.

## Assignment

- [Memory-controller diagram and data-flow walkthrough](https://github.com/SiliconBadgers/rtl-memory/issues/2)

1. Use the central diagram and Software evidence to map weights/scales, activations, partial sums, KV data and recurrent/convolution state.
2. Define request handling, addressing, arbitration, banking/ports, buffering, transfer sequencing and responses. Explain backpressure, outstanding transactions, ownership/reuse and error/reset behavior.
3. Check in a Mermaid or editable draw.io diagram and a representative load -> compute -> store walkthrough with interface explanations.
4. Keep first-chip SRAM assumptions distinct from external-memory/platform studies. State uncertain sizes, bandwidths and latencies so the work proceeds with Control and each Compute team in parallel.

## Starting evidence

- [Central diagram](https://github.com/SiliconBadgers/architecture/blob/main/docs/accelerator-diagram.md)
- [Recorded Software profiling package](https://github.com/SiliconBadgers/software/tree/main/experiments/llama-cpp/2026-09-22)

## Artifact locations

| Location | What belongs here |
|---|---|
| [docs/controller/](../docs/controller/README.md) | Memory-controller diagram, block/interface descriptions, load-compute-store traces and open assumptions for rtl-memory#2. Include editable source and a preview for draw.io. |

## What runs today

The repo provides design scaffolding. A controller implementation and its verification results are still to be developed.

These folders organize the work; they do not complete the issues. Use the
existing evidence now and publish useful intermediate results. Arrange a team
meeting this week to divide the work and agree on next steps.

Follow [CONTRIBUTING.md](../CONTRIBUTING.md) before editing or committing.
