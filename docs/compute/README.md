# Compute

Read [the current assignment](START-HERE.md), [charter](CHARTER.md) and [objectives](OBJECTIVES.md).
Sources live in `rtl/compute/` at the repository root.

The [Matrix Unit I/O scheme](matrix_unit_io_scheme.md) describes the proposed
output-stationary INT8/INT4 array, block scaling, retained accumulators, and
SRAM wrapper. Implementation and verification are separate work.

The [matrix unit specification](matrix_unit_spec.md) develops the
output-stationary design, accumulator lifetime and block-scaled arithmetic,
with logical edge masks, selected output formats, a provisional command record,
and pipelined K contributions.
