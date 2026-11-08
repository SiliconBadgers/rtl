// Output conversion for the Matrix unit: one finished C row from the array, in its
// native form, becomes the row in the command's output encoding
// (docs/compute/matrix_unit_spec.md, "Output representations"):
//
//   0 legacy   INT32 for integer commands, FP32 for block-scaled ones   4 bytes
//   1 INT32    saturate32(RNE(v * 2^frac))                              4 bytes
//   2 FP32     IEEE binary32, nearest even                              4 bytes
//   3 FP16     IEEE binary16, nearest even, subnormals kept, rounded    2 bytes
//              directly from the native value (no FP32 step)
//   4 INT8     clamp(RNE(a * mul / 2^shift), -127, 127)                 1 byte
//
// with a the native code (the AccW-bit integer sum, or the Q23.24 code of a block-
// scaled sum) and v its value (a, or a / 2^24). Block-scaled flags: NaN gives the
// canonical NaN (FP32 0x7FC00000, FP16 0x7E00) or integer 0; overflow gives signed
// infinity or the integer endpoint (INT32 -2^31 or 2^31 - 1, INT8 -127 or 127), with
// the accumulator's sign; a zero sum gives +0. Each lane's element sits in the low
// bytes of its 32-bit output lane, the rest zero; the wrapper packs them.
//
// The arithmetic is bpu_sa_pkg::cv_stage1 and cv_stage2. Stage 1 (registered here)
// takes the magnitude, its leading one and the product a * mul (2^frac for INT32),
// 48 x 32 bits; stage 2 (combinational from the register) rounds and saturates.
// INT32 and INT8 share stage 2: INT32 is the product with 2^frac shifted right by the
// native fractional bits (24 or 0).
//
// Timing: out_valid_o and out_o follow in_valid_i by one clock edge, like the
// conversion register they replace. The format fields must hold while a row is in
// the register (the wrapper holds them for the whole command).
module bpu_sa_output_convert
  import bpu_sa_pkg::*;
#(
  parameter int unsigned Lanes = 8,  // C columns
  parameter int unsigned AccW  = 32  // integer sum width, 16 .. 32
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,
  input  logic                       in_valid_i,   // take a row this cycle
  input  logic                       in_scaled_i,  // block-scaled row (else integer)
  input  logic [     Lanes*AccW-1:0] in_int_i,     // integer sums, AccW each
  input  logic [Lanes*FX_PACK_W-1:0] in_fx_i,      // block-scaled {nan, overflow, value}
  input  logic [                2:0] fmt_i,
  input  logic [                5:0] frac_i,       // INT32 fractional bits, 0 .. 31
  input  logic [               31:0] mul_i,        // INT8 multiplier
  input  logic [                6:0] shift_i,      // INT8 right shift
  output logic                       out_valid_o,
  output logic [       Lanes*32-1:0] out_o
);

  cv_mid_t [Lanes-1:0] mid_q;
  logic [Lanes*32-1:0] int32;  // the integer sums, sign-extended to 32 bits
  logic valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= 1'b0;
    end else begin
      valid_q <= in_valid_i;
    end
  end

  for (genvar j = 0; j < Lanes; j++) begin : g_lane
    assign int32[32*j+:32] = 32'($signed(in_int_i[AccW*j+:AccW]));
    // The stage-1 register is data storage: not reset.
    always_ff @(posedge clk_i) begin
      if (in_valid_i) begin
        mid_q[j] <= cv_stage1(in_scaled_i, int32[32*j+:32], in_fx_i[FX_PACK_W*j+:FX_PACK_W], fmt_i,
                              frac_i, mul_i);
      end
    end
    assign out_o[32*j+:32] = cv_stage2(mid_q[j], fmt_i, shift_i);
  end

  assign out_valid_o = valid_q;

endmodule
