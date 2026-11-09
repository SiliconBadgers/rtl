// Round an exact value to an IEEE 754 format, round-to-nearest ties-to-even.
// Value = (-1)^sign * mag * 2^exponent, plus a positive amount smaller than one
// unit of mag's last bit when sticky_i is set (used for inexact quotients and roots).
// When sticky_i can be set, mag must carry at least FracBits+3 significant bits so the
// sticky amount always lies below the guard bit.
// Subnormals are kept. A value that rounds to zero keeps its sign.
// overflow: the result rounds to infinity (d is then not meaningful).
module fp_round #(
  parameter int ExpBits  = 5,
  parameter int FracBits = 10
) (
  input  logic            sign_i,
  input  logic [63:0]     mag_i,
  input  integer          exponent_i,
  input  logic            sticky_i,
  output logic [ExpBits+FracBits:0] d_o,
  output logic            overflow_o
);
  localparam int BIAS    = (1 << (ExpBits - 1)) - 1;
  localparam int UNIT    = 1 - BIAS - FracBits;      // smallest subnormal step: F16 -24, F32 -149
  localparam int EXP_MAX = (1 << ExpBits) - 1;

  logic [127:0] extended;
  logic [FracBits+1:0] kept, rounded;
  logic guard_bit, sticky_bit, round_up;
  integer msb, lsb_exponent, right_shift, exponent_field;

  always_comb begin
    extended = {64'b0, mag_i};
    kept = '0;
    rounded = '0;
    guard_bit = 1'b0;
    sticky_bit = sticky_i;
    round_up = 1'b0;
    msb = -1;
    lsb_exponent = UNIT;
    right_shift = 0;
    exponent_field = 0;
    overflow_o = 1'b0;
    d_o = {sign_i, {(ExpBits+FracBits){1'b0}}};

    for (int i = 0; i < 64; i++) begin
      if (mag_i[i]) begin
        msb = i;
      end
    end

    if (msb >= 0) begin
      // Exponent of the result's last bit: FracBits+1 significant bits, but never
      // below the smallest subnormal step.
      lsb_exponent = (msb + exponent_i - FracBits > UNIT) ? msb + exponent_i - FracBits : UNIT;
      right_shift = lsb_exponent - exponent_i;

      if (right_shift <= 0) begin
        // Exact: mag already fits in FracBits+1 bits at this exponent.
        kept = (FracBits+2)'(mag_i << (-right_shift));
      end else if (right_shift > 65) begin
        // mag < 2^64, so the value is below a quarter of the smallest step.
        sticky_bit = 1'b1;
      end else begin
        kept = (FracBits+2)'(extended >> right_shift);
        guard_bit = extended[right_shift-1];
        for (int i = 0; i < 64; i++) begin
          if (i < right_shift-1) begin
            sticky_bit = sticky_bit | mag_i[i];
          end
        end
      end

      round_up = guard_bit && (sticky_bit || kept[0]);
      rounded = kept + (FracBits+2)'(round_up);

      // Rounding can carry into a new bit: renormalize.
      if (rounded[FracBits+1]) begin
        rounded = rounded >> 1;
        lsb_exponent = lsb_exponent + 1;
      end

      // Normal results have the implicit bit set; otherwise subnormal or zero.
      exponent_field = rounded[FracBits] ? lsb_exponent - UNIT + 1 : 0;

      if (exponent_field >= EXP_MAX) begin
        overflow_o = 1'b1;
      end else begin
        d_o = {sign_i, exponent_field[ExpBits-1:0], rounded[FracBits-1:0]};
      end
    end
  end

endmodule
