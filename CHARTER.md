# RTL implementation

This repository owns accelerator compute datapaths, execution sequencing and
memory/data-movement blocks. Their responsibilities remain described by the
[Compute](docs/compute/CHARTER.md), [Control](docs/control/CHARTER.md) and
[Memory](docs/memory/CHARTER.md) charters.

The SoC repository owns system composition, CPU wrappers, host-facing access
and platform adaptation. Architecture coordinates system requirements and
shared specifications. Software supplies workload evidence and runtime behavior;
Verification provides independent assessment.

Changes spanning RTL areas are reviewed and tested together. Shared block
interfaces are agreed with their consumers; consolidation does not approve
pending proposals or settle numerical formats, command semantics or memory
organization.
