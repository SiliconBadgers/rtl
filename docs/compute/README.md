# Compute

Read [the current assignment](START-HERE.md), [charter](CHARTER.md) and [objectives](OBJECTIVES.md).
Sources live in `rtl/compute/` at the repository root.

The [Matrix Unit I/O scheme](matrix_unit_io_scheme.md) describes the Matrix Unit:
its command and SRAM-arbiter interfaces, memory layout, arithmetic and timing.
Its figures and verification plan are in [matrix_unit/](matrix_unit/README.md).
The [block specification](bpu_matrix_unit_spec.md) is the contract for `bpu_matrix_unit`, the
top level the controller instantiates: ports, record, protocol rules and numbered requirements,
mapped to their tests in [bpu_matrix_unit_requirements.csv](bpu_matrix_unit_requirements.csv).
Update the guide alongside RTL changes.
