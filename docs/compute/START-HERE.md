# Compute research: two independent proposals: current work

Compute1 and Compute2 each investigate the full compute-unit design question and produce their own proposal. They are not splitting arithmetic versus stateful work, and neither team depends on or coordinates its proposal with the other.

## Assignment

- [Research the complete compute-unit design](https://github.com/SiliconBadgers/rtl/issues/2)

1. Each team covers matrix/vector arithmetic, projections/output head, attention, DeltaNet/recurrent state, convolution, normalization/activation and layout work.
2. For each operation, identify arithmetic, sequencing, local control, persistent state and temporary storage. Use Software's existing shapes/formats and profiling evidence now.
3. Compare shared datapaths with distinct resources/state/control, accounting for prefill/decode utilization, precision, operand bandwidth, buffering and data movement.
4. Each team checks in its own research note, operation-to-unit mapping, candidate block diagram and recommendation with alternatives, evidence and open questions. Share emerging interfaces with Memory and Control independently.

## Starting evidence

- [Central diagram](https://github.com/SiliconBadgers/architecture/blob/main/docs/accelerator-diagram.md)
- [Recorded Software profiling package](https://github.com/SiliconBadgers/software/tree/main/experiments/llama-cpp/2026-09-22)

## Artifact locations

| Location | What belongs here |
|---|---|
| [research/compute1/](../../research/compute1/README.md) | Compute1's complete independent investigation and proposal for rtl#2. Cover the full operation set; divide tasks within Compute1. |
| [research/compute2/](../../research/compute2/README.md) | Compute2's complete independent investigation and proposal for rtl#2. Cover the full operation set; divide tasks within Compute2. |

## What runs today

The signed MAC is a runnable example. The four functional boxes in Architecture do not commit the project to four engines. No final unit allocation is established here.

These folders organize the work; they do not complete the issues. Use the
existing evidence now and publish useful intermediate results. Arrange a team
meeting this week to divide the work and agree on next steps.

Follow [CONTRIBUTING.md](CONTRIBUTING.md) before editing or committing.
