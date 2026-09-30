# Memory and data movement: team charter

Current assignments are listed in [docs/START-HERE.md](docs/START-HERE.md) and
the linked issues. The broader directions below provide context; they do not
replace those deliverables.

## Purpose

Understand and develop how data is stored, accessed and moved within the accelerator. The team makes memory behavior and its performance consequences explicit, supporting useful computation while balancing capacity, bandwidth, latency, cost and implementation constraints.

Data access can shape the effectiveness of the entire accelerator. This team connects workload access patterns to storage organization and movement mechanisms. Its contributions can include access-pattern studies, architecture comparisons, interface explanations, behavioral models, RTL or measurements.

## Responsibilities

### Storage organization

Study capacity, locality, banking, buffering, ports and storage hierarchy choices in the context of the project’s workloads. Explain the assumptions behind the chosen organization.

### Movement and access behavior

Own memory-side access mechanisms, queues, arbitration and data movement services within the agreed subsystem boundary. DMA is one possible mechanism when the system needs it, not a predetermined deliverable.

### Memory semantics

Make addressing, ordering, conflicts, response behavior, initialization and reset implications understandable to consumers. Participate in establishing shared contracts for externally visible behavior.

### Memory feasibility and performance

Investigate bandwidth demand, contention, reuse and physical storage constraints. Distinguish behavioral abstractions from realizable resources and preserve evidence behind estimates.

## Boundaries and shared decisions

rtl-memory owns the storage subsystem and its access services. rtl-control decides when accelerator operations request those services; rtl-compute owns local arithmetic behavior; soc connects subsystem and host interfaces. Architecture coordinates the shared address and data model. Physical-design informs storage implementation options, and SoC owns platform-specific adaptation of external memory resources. Exact routing and protocol boundaries are agreed where these responsibilities meet.

## Member autonomy

Members may investigate access patterns, compare banking approaches, examine buffering policies, build storage models, explain an interface or develop memory hardware. The team chooses internal organization and methods within agreed semantics. Proposals that alter visible capacity, ordering, addressing or performance assumptions are discussed with consumers rather than decided in isolation.

## Collaboration

| Partners | Shared concerns |
|---|---|
| architecture and software | Use workload dimensions, layouts and access patterns to examine what the storage system needs to support. |
| rtl-control, rtl-compute and soc | Exchange request patterns and interface assumptions; clarify ordering, contention and response behavior at subsystem boundaries. |
| verification and physical-design | Work together on correctness evidence and on the gap between an abstract storage model and an actual target implementation. |

## Possible directions

Possible directions include a memory access study, a comparison of buffer organizations, an explanation of conflicting accesses, a behavioral storage model, an arbitration experiment or an investigation of available storage primitives. Members choose which uncertainty or capability is worth pursuing.

## What progress means

Progress is visible when data movement requirements are understood, consumers can reason about storage behavior, and design choices have a defensible relationship to workload and platform constraints. A study that exposes a bandwidth bottleneck or clarifies ambiguous ordering is a substantive contribution.

Leads help members interpret this purpose, find collaborators, access resources
and share what they learn. Members choose their questions and contributions.
Research, design reasoning, experiments, implementation, documentation and
teaching can all advance the charter; success is not measured by the number of
code changes or completed tickets.

The team can revise this charter as its understanding evolves. Changes to a
shared boundary or commitment are discussed with the teams affected by them.
The [objectives](OBJECTIVES.md) describe durable outcomes, and the
[repository structure](README.md#repository-structure) provides places to develop
work without specifying a mandatory project or sequence.
