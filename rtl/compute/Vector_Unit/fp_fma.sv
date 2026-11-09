// Combinational IEEE 754 fused multiply-add D = A*B + C, round-to-nearest ties-to-even.
// The exact product and sum are formed first, then rounded once.
// A and B share one format; C and D share another (F16/F16, F32/F32, F16/F32).
// Inputs must be finite. error: NaN/Inf input, or the result rounds to infinity.
module fp_fma #(
  parameter int AbExpBits  = 5,
  parameter int AbFracBits = 10,
  parameter int CdExpBits  = 5,
  parameter int CdFracBits = 10
) (
  input  logic [AbExpBits+AbFracBits:0] a_i,
  input  logic [AbExpBits+AbFracBits:0] b_i,
  input  logic [CdExpBits+CdFracBits:0] c_i,
  output logic [CdExpBits+CdFracBits:0] d_o,
  output logic                    error_o
);
  localparam int AB_BIAS = (1 << (AbExpBits - 1)) - 1;
  localparam int CD_BIAS = (1 << (CdExpBits - 1)) - 1;

  // Exponent of the smallest subnormal step: F16 -24, F32 -149.
  localparam int AB_UNIT = 1 - AB_BIAS - AbFracBits;
  localparam int CD_UNIT = 1 - CD_BIAS - CdFracBits;
  localparam int P_UNIT  = 2 * AB_UNIT;

  // All magnitudes are held exactly in units of 2^UNIT.
  localparam int UNIT    = (P_UNIT < CD_UNIT) ? P_UNIT : CD_UNIT;
  localparam int P_ALIGN = P_UNIT - UNIT;
  localparam int C_ALIGN = CD_UNIT - UNIT;

  // Largest finite magnitudes, in bits, plus one bit for the sum carry.
  localparam int P_WIDTH = 2 * (AbFracBits + 1) + 2 * ((1 << AbExpBits) - 3) + P_ALIGN;
  localparam int C_WIDTH = (CdFracBits + 1) + ((1 << CdExpBits) - 3) + C_ALIGN;
  localparam int Width   = ((P_WIDTH > C_WIDTH) ? P_WIDTH : C_WIDTH) + 1;

  localparam int KEPT_WIDTH = CdFracBits + 2;
  localparam int EXP_MAX    = (1 << CdExpBits) - 1;

  logic sign_a, sign_b, sign_c, sign_p, sign_result;
  logic [AbExpBits-1:0] exp_a, exp_b;
  logic [CdExpBits-1:0] exp_c;
  logic [AbFracBits:0] sig_a, sig_b;
  logic [CdFracBits:0] sig_c;
  logic [2*AbFracBits+1:0] sig_p;
  logic [Width-1:0] mag_p, mag_c, magnitude;
  logic [KEPT_WIDTH-1:0] kept, rounded;
  logic guard_bit, sticky_bit, round_up;
  integer shift_a, shift_b, shift_c;
  integer msb, right_shift, exponent_result;

  always_comb begin
    sign_a = a_i[AbExpBits+AbFracBits];
    sign_b = b_i[AbExpBits+AbFracBits];
    sign_c = c_i[CdExpBits+CdFracBits];
    sign_p = sign_a ^ sign_b;
    exp_a = a_i[AbExpBits+AbFracBits-1:AbFracBits];
    exp_b = b_i[AbExpBits+AbFracBits-1:AbFracBits];
    exp_c = c_i[CdExpBits+CdFracBits-1:CdFracBits];

    // The implicit leading bit is zero for subnormals and zero.
    sig_a = {(exp_a != 0), a_i[AbFracBits-1:0]};
    sig_b = {(exp_b != 0), b_i[AbFracBits-1:0]};
    sig_c = {(exp_c != 0), c_i[CdFracBits-1:0]};

    // Normal: significand * 2^(exp - 1) subnormal steps. Subnormal: significand.
    shift_a = (exp_a == 0) ? 0 : int'(exp_a) - 1;
    shift_b = (exp_b == 0) ? 0 : int'(exp_b) - 1;
    shift_c = (exp_c == 0) ? 0 : int'(exp_c) - 1;

    // Exact product and addend, aligned to the common unit.
    sig_p = sig_a * sig_b;
    mag_p = Width'(sig_p) << (shift_a + shift_b + P_ALIGN);
    mag_c = Width'(sig_c) << (shift_c + C_ALIGN);

    sign_result = 1'b0;
    magnitude = '0;
    kept = '0;
    rounded = '0;
    guard_bit = 1'b0;
    sticky_bit = 1'b0;
    round_up = 1'b0;
    msb = -1;
    right_shift = 0;
    exponent_result = 0;
    d_o = '0;

    error_o = (&exp_a) || (&exp_b) || (&exp_c);

    if (sign_p == sign_c) begin
      magnitude = mag_p + mag_c;
      sign_result = sign_p;
    end else if (mag_p >= mag_c) begin
      magnitude = mag_p - mag_c;
      sign_result = sign_p;
    end else begin
      magnitude = mag_c - mag_p;
      sign_result = sign_c;
    end

    if (magnitude == 0) begin
      // Exact zero is +0 under RNE, except (-0) + (-0).
      d_o = {((mag_p == 0) && (mag_c == 0) && sign_p && sign_c), {(CdExpBits+CdFracBits){1'b0}}};
    end else begin
      // Find highest set bit of the exact magnitude.
      for (int i = 0; i < Width; i++) begin
        if (magnitude[i]) begin
          msb = i;
        end
      end

      // Keep CdFracBits+1 significant bits, but never go below the output's
      // subnormal step (C_ALIGN units).
      right_shift = (msb - CdFracBits > C_ALIGN) ? msb - CdFracBits : C_ALIGN;
      kept = KEPT_WIDTH'(magnitude >> right_shift);

      // Guard and sticky encode all discarded bits.
      if (right_shift > 0) begin
        guard_bit = magnitude[right_shift-1];
        for (int i = 0; i < Width; i++) begin
          if (i < right_shift-1) begin
            sticky_bit = sticky_bit | magnitude[i];
          end
        end
      end
      round_up = guard_bit && (sticky_bit || kept[0]);
      rounded = kept + KEPT_WIDTH'(round_up);

      // Biased exponent minus one; zero for subnormals.
      exponent_result = right_shift - C_ALIGN;

      // Rounding can overflow the significand into the next exponent.
      if (rounded[CdFracBits+1]) begin
        rounded = rounded >> 1;
        exponent_result = exponent_result + 1;
      end

      // The implicit bit adds one to the exponent field. A subnormal that
      // rounds up to 2^CdFracBits becomes the smallest normal this way.
      exponent_result = exponent_result + int'(rounded[CdFracBits]);

      if (exponent_result >= EXP_MAX) begin
        // Overflow is outside the finite-result contract.
        error_o = 1'b1;
        d_o = {sign_result, {CdExpBits{1'b1}}, {CdFracBits{1'b0}}};
      end else begin
        d_o = {sign_result, CdExpBits'(exponent_result), rounded[CdFracBits-1:0]};
      end
    end
  end
endmodule
