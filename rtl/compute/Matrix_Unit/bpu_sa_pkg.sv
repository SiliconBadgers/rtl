// Numerics constants of the Matrix Unit's block-scaled path, shared by bpu_sa_pe,
// bpu_sa_array and bpu_sa_sram_wrapper. The full contract is in
// docs/compute/matrix_unit_io_scheme.md (Arithmetic). These values are the
// implementation's defaults; the team has not yet fixed the format.
package bpu_sa_pkg;

  // Not every importer uses every constant.
  /* verilator lint_off UNUSEDPARAM */

  // The scaled accumulator in each PE: signed fixed point, FX_W bits with FX_FRAC
  // fractional bits (Q23.24): it holds integer / 2^FX_FRAC.
  localparam int unsigned FX_W = 48;
  localparam int unsigned FX_FRAC = 24;

  // A drained block-scaled result: {nan, overflow, value}.
  localparam int unsigned FX_PACK_W = FX_W + 2;

  // Cycles from the edge that takes a block's last k-step into a PE to the edge that
  // updates the PE's scaled accumulator (and, for a tile's final block, its shadow).
  localparam int unsigned SCALE_PIPE = 4;

  // A bf16 scale is (-1)^s * m * 2^(e - 127 - 7) with m = {1, mantissa} (8 bits), so
  //   isum * sa * sb * 2^FX_FRAC = isum * ma * mb * 2^(ea + eb - SCALE_SHIFT_BIAS).
  localparam int unsigned SCALE_SHIFT_BIAS = 2 * (127 + 7) - FX_FRAC;

  /* verilator lint_on UNUSEDPARAM */

endpackage
