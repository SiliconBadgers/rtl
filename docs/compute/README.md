# Compute

Read [the current assignment](START-HERE.md), [charter](CHARTER.md) and [objectives](OBJECTIVES.md).
Sources live in `rtl/compute/` at the repository root.

The [Matrix Unit I/O scheme](matrix_unit_io_scheme.md) describes the Matrix Unit:
its command and SRAM-arbiter interfaces, memory layout, arithmetic and timing.
Its figures and verification plan are in [matrix_unit/](matrix_unit/README.md).
Update the guide alongside RTL changes.

The [matrix unit specification](matrix_unit_spec.md) proposes extensions to that
implementation: logical edge masks, additional output formats, a provisional
command record, and overlapping K contributions. Those extensions remain design
work; the I/O scheme describes the current RTL.
