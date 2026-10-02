# Compute datapaths: team charter

Current assignments are listed in [docs/START-HERE.md](START-HERE.md) and
the linked issues. The broader directions below provide context; they do not
replace those deliverables.

## Purpose

Explore and develop the arithmetic capabilities that turn the accelerator’s intended computations into effective hardware. The team seeks a sound balance among numerical behavior, throughput, latency, area and implementation complexity, using approaches its members choose.

Compute is where numerical operations meet hardware organization. Useful contributions can explain an arithmetic choice, investigate a datapath organization, demonstrate an operator, measure a tradeoff or make an existing block easier to understand. The team’s mandate is broader than extending the existing MAC example.

## Responsibilities

### Arithmetic behavior and organization

Study and develop arithmetic operators, processing elements, vector or matrix datapaths and related transformations appropriate to the agreed workloads. Explain the relationship between numerical semantics and hardware behavior.

### Local execution structure

Own the pipelines, local operand handling and datapath coordination that belong inside compute blocks. Make externally relevant latency, acceptance and result behavior understandable to consumers.

### Compute tradeoffs

Investigate precision, parallelism, reuse, utilization and implementation cost. Distinguish analytical expectations, simulation observations and mapped hardware results.

### Reusable understanding

Preserve explanations, experiments, local checks and implementation knowledge so members can compare approaches and build on one another’s work.

## Boundaries and shared decisions

This team owns arithmetic implementation and its internal pipelines. The control team coordinates operations across blocks; the memory team owns storage and movement services; soc owns system composition. Architecture and software help establish shared numerical semantics. Verification contributes independent correctness assessment, while physical-design provides implementation feedback. A choice that changes visible timing or numerical behavior is discussed with the relevant consumers.

## Member autonomy

Members choose operators or design questions that serve the charter and their interests. Research, numerical analysis, hardware experiments, educational examples and implementation work are all valid directions. Internal datapath choices belong to the team within agreed interfaces. The current signed MAC can support exploration, but it does not prescribe the team’s next block, final precision or architecture.

## Collaboration

| Partners | Shared concerns |
|---|---|
| architecture and software | Exchange operation requirements, numerical assumptions and reference behavior so compute choices remain meaningful to the workload. |
| the control team and the memory team | Agree on operand availability, operation acceptance, result handling and the assumptions that affect scheduling or data movement. |
| verification and physical-design | Share behavior and constraints; use independent checks and implementation measurements to assess the strengths and limits of a design. |

## Possible directions

Members might study numerical representations, compare pipeline organizations, investigate an activation or normalization operation, explain array utilization, build a small datapath or characterize an existing one. A compelling direction should connect to a charter objective; it need not produce a new production module.

## What progress means

Progress means arithmetic behavior and its costs are better understood, useful compute capabilities become dependable, and consumers can reason about their use. Evidence can be a numerical comparison, a clear block explanation, a verified implementation or a measured tradeoff with stated assumptions.

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
