# Compute

Read [the current assignment](START-HERE.md), [charter](CHARTER.md) and [objectives](OBJECTIVES.md).
Sources live in `rtl/compute/` at the repository root.

The [Matrix Unit I/O scheme](matrix_unit_io_scheme.md) describes the Matrix Unit:
its command and SRAM-arbiter interfaces, memory layout, arithmetic and timing.
Its figures and verification plan are in [matrix_unit/](matrix_unit/README.md).
The [integration contract](matrix_unit_integration.md) is what the controller, arbiter and
verification owners connect to: `bpu_matrix_unit`'s ports, milestones, idle, fault and reset.
Update the guide alongside RTL changes.
