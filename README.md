# SiliconBadgers RTL

Compute datapaths, execution control and memory blocks for the SiliconBadgers
accelerator live in this repository. The [SoC repository](https://github.com/SiliconBadgers/soc)
owns CPU and host interfaces, platform adaptation and system composition.

## Current work

| Area | Source | Design material | Assignment |
|---|---|---|---|
| Compute | `rtl/compute/` | [Compute guide](docs/compute/START-HERE.md), `research/compute1/`, `research/compute2/` | [Compute research #2](https://github.com/SiliconBadgers/rtl/issues/2) |
| Control | `rtl/control/` | [Control guide](docs/control/START-HERE.md), `docs/control/controller/` | [Controller design #6](https://github.com/SiliconBadgers/rtl/issues/6) |
| Memory | `rtl/memory/` | [Memory guide](docs/memory/START-HERE.md), `docs/memory/controller/` | [Memory design #7](https://github.com/SiliconBadgers/rtl/issues/7) |

Compute1 and Compute2 each produce a complete independent compute proposal.
The repository consolidation does not divide their operation coverage or select
an engine count. Team charters and objectives remain under `docs/<area>/`.

## Existing implementation

The signed INT8 MAC with an INT32 accumulator is a runnable example in
[rtl/compute/pe_mac.sv](rtl/compute/pe_mac.sv). Control and memory design work
remains provisional. A [single-command routing pilot](docs/control/command-router.md)
and its shared command package are also available; the SoC harness exercises
them with error-returning engine fixtures. The MAC example does not establish full-accelerator
correctness, throughput or physical feasibility.

## Build and contribute

Read [SETUP.md](SETUP.md) for tools and tests and [CONTRIBUTING.md](CONTRIBUTING.md)
for the review workflow. Shared block packages live in `rtl/common/`.
Block tests belong under `tb/<area>/`; independent verification
remains in the [Verification repository](https://github.com/SiliconBadgers/verification).

[Shared architecture](https://github.com/SiliconBadgers/architecture/blob/main/docs/accelerator-diagram.md)
provides system context. This repository preserves the histories of the former
compute, control and memory repositories; existing source notices remain intact.

[Preserved development history](docs/history/README.md) contains the original
control and memory reviews, branch mappings and authorship records.
