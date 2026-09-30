# Execution control and scheduling: team charter

Current assignments are listed in [docs/START-HERE.md](docs/START-HERE.md) and
the linked issues. The broader directions below provide context; they do not
replace those deliverables.

## Purpose

Make accelerator execution understandable and dependable by coordinating operations, resources and progress over time. The team explores how commands become ordered activity across compute and memory, including dependencies, stalls, completion and recovery.

Execution control connects the programming model to the behavior of hardware blocks. Its design affects utilization, predictability and the ability to reason about a running system. The team can contribute through state and scheduling models, design explanations, protocol studies, experiments or hardware implementations.

## Responsibilities

### Execution semantics

Develop a clear model of command acceptance, progress, completion and exceptional conditions in collaboration with architecture and software. Make state and sequencing behavior visible enough for others to reason about it.

### Scheduling and coordination

Study and develop operation ordering, dependencies, hazards, resource use and coordination among compute and memory services. Explore alternative scheduling approaches where they serve project objectives.

### Liveness and recovery

Reason about stalls, backpressure, reset, cancellation or error behavior appropriate to the agreed design. Explain conditions under which work can progress or needs intervention.

### Control knowledge and implementation

Maintain useful state diagrams, scheduling analyses, interface models, design rationale and implementation artifacts. Link internal choices to externally visible behavior.

## Boundaries and shared decisions

rtl-control owns execution sequencing across accelerator operations. soc owns host-facing access, register/address decoding and system wiring; rtl-memory owns access and transfer machinery; rtl-compute owns arithmetic and internal datapath timing. Architecture stewards shared execution semantics with these teams. The control/SoC boundary must make configuration, launch, status and error ownership explicit without merging their charters.

## Member autonomy

Members can choose to study scheduling strategies, model dependencies, examine deadlock conditions, explain a protocol, prototype a controller or improve an existing design. The team chooses its internal representation and implementation approach. Changes to command meaning or behavior seen by other blocks require shared agreement. No particular sequencer, command set or scheduling policy is mandated by the scaffold.

## Collaboration

| Partners | Shared concerns |
|---|---|
| architecture and software | Connect intended operation semantics and software expectations to a realizable execution model. |
| rtl-compute and rtl-memory | Agree on operation requests, resource availability, responses and the assumptions required for progress. |
| soc and verification | Clarify the host-to-execution boundary and collaborate on observations that demonstrate correct ordering, progress and recovery. |

## Possible directions

Members might compare centralized and distributed scheduling, investigate hazards, draw execution traces, analyze stalled transactions, develop a small controller or explain a recovery strategy. These are possible lines of inquiry; the team chooses its own work in service of the charter.

## What progress means

Progress means the project can explain how operations execute, identify when progress is possible, and connect execution behavior to correctness and performance. State models, reasoned scheduling comparisons, verification findings and implementations can all supply useful evidence.

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
