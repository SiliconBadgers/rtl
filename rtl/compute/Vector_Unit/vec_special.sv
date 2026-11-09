// SPECIAL family: FP DIV/RCP, integer DIVMOD and DIV_RNE, ISQRT, ExpBits, RSQRT.
// Every result is rounded once from the exact value. result2 is DIVMOD's remainder.
//
// Multi-cycle operations (no '/' or '%' in the datapath):
//   DIV, RCP, DIVMOD, DIV_RNE : one shared sequential divider (div_iter)
//                               I32/U32 32 cycles, I64/U64 64 cycles, F16/F32 50 cycles
//   RSQRT                     : sequential root search (fp_rsqrt), 28 cycles
// vec_simd pulses start; a and b must stay stable until finished.
// ISQRT and ExpBits are combinational: finished is held high for them.
module vec_special (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        start_i,             // first cycle of a multi-cycle operation
  input  logic [63:0] a_i,
  input  logic [63:0] b_i,
  input  logic [6:0]  sig_i,
  output logic        finished_o,          // result below is valid
  output logic        error_o,
  output logic [63:0] result_o,
  output logic [63:0] result2_o
);

  // SPECIAL SIG encodings (Signatures sheet)
  localparam logic [6:0] DIV_F16     = 7'd0;
  localparam logic [6:0] DIV_F32     = 7'd1;
  localparam logic [6:0] RCP_F16     = 7'd2;
  localparam logic [6:0] RCP_F32     = 7'd3;
  localparam logic [6:0] DIVMOD_I32  = 7'd4;
  localparam logic [6:0] DIVMOD_U32  = 7'd5;
  localparam logic [6:0] DIVMOD_I64  = 7'd6;
  localparam logic [6:0] DIVMOD_U64  = 7'd7;
  localparam logic [6:0] DIV_RNE_I32 = 7'd8;
  localparam logic [6:0] DIV_RNE_U32 = 7'd9;
  localparam logic [6:0] DIV_RNE_I64 = 7'd10;
  localparam logic [6:0] DIV_RNE_U64 = 7'd11;
  localparam logic [6:0] ISQRT_U32   = 7'd12;
  localparam logic [6:0] ISQRT_U64   = 7'd13;
  localparam logic [6:0] EXP_F16     = 7'd14;
  localparam logic [6:0] EXP_F32     = 7'd15;
  localparam logic [6:0] RSQRT_F16   = 7'd16;
  localparam logic [6:0] RSQRT_F32   = 7'd17;

  localparam logic [31:0] F32_ONE = 32'h3F80_0000;

  // The FP quotient keeps K extra bits: 24-bit significands give 26..27 quotient bits.
  localparam int K = 26;

  logic fp_div_op, f16_op, int_div_op, rsqrt_op;

  // FP division (F16 operands are widened exactly to F32)
  logic [31:0] num32, den32;
  logic [7:0]  exp_n, exp_d;
  logic [23:0] sig_n, sig_d, norm_n, norm_d;
  integer      msb_n, msb_d, e_n, e_d, q_exponent;
  logic        fp_input_error, fp_sign;
  logic [15:0] fdiv16_result;
  logic [31:0] fdiv32_result;
  logic        fdiv16_overflow, fdiv32_overflow;

  // Integer division on magnitudes
  logic        int_signed, int_wide;
  logic        sign_a, sign_b, quotient_negative;
  logic [63:0] mag_a, mag_b, mag_q, mag_r;
  logic [64:0] mag_rne;
  logic [64:0] limit_positive, limit_negative;
  logic        round_up, quotient_overflow, rne_overflow;
  logic [63:0] quotient, remainder, rne_quotient;

  // Shared divider
  logic [6:0]  div_iterations;
  logic [63:0] div_dividend, div_divisor, div_quotient, div_remainder;
  logic        div_busy, div_finished;

  // RSQRT and ExpBits
  logic [31:0] unary_input;
  logic [15:0] rsqrt16_result, exp16_result;
  logic [31:0] rsqrt32_result, exp32_result;
  logic        rsqrt16_error, rsqrt32_error, exp16_error, exp32_error;
  logic        rsqrt_busy, rsqrt_finished;

  // Exact F16 -> F32 widening (subnormals become normal; NaN/Inf stay NaN/Inf).
  function automatic logic [31:0] f16_to_f32(input logic [15:0] h);
    integer msb;
    logic [10:0] shifted;
    f16_to_f32 = {h[15], 31'b0};
    if (h[14:10] == 5'd31) begin
      f16_to_f32 = {h[15], 8'hFF, h[9:0], 13'b0};
    end else if (h[14:10] != 5'd0) begin
      f16_to_f32 = {h[15], ({3'b0, h[14:10]} + 8'd112), h[9:0], 13'b0};
    end else if (h[9:0] != 10'd0) begin
      // Subnormal: h[9:0] * 2^-24 with its top bit at position msb.
      msb = 0;
      for (int i = 0; i < 10; i++) begin
        if (h[i]) begin
          msb = i;
        end
      end
      shifted = {1'b0, h[9:0]} << (10 - msb);
      f16_to_f32 = {h[15], 8'(msb + 103), shifted[9:0], 13'b0};
    end
  endfunction

  // Floor square root of a 64-bit value, one result bit per step (no division).
  function automatic logic [63:0] isqrt64(input logic [63:0] value);
    logic [63:0] op, res, one;
    op = value;
    res = 64'b0;
    one = 64'h4000_0000_0000_0000;
    for (int i = 0; i < 32; i++) begin
      if (op >= res + one) begin
        op = op - (res + one);
        res = (res >> 1) + one;
      end else begin
        res = res >> 1;
      end
      one = one >> 2;
    end
    isqrt64 = res;
  endfunction

  assign fp_div_op  = (sig_i <= RCP_F32);
  assign int_div_op = (sig_i >= DIVMOD_I32) && (sig_i <= DIV_RNE_U64);
  assign rsqrt_op   = (sig_i == RSQRT_F16) || (sig_i == RSQRT_F32);
  assign f16_op     = (sig_i == DIV_F16) || (sig_i == RCP_F16) ||
                      (sig_i == EXP_F16) || (sig_i == RSQRT_F16);

  // ---------------------------------------------------------------- FP DIV / RCP
  // RCP is DIV with a numerator of one.
  always_comb begin
    case (sig_i)
      DIV_F16: begin num32 = f16_to_f32(a_i[15:0]); den32 = f16_to_f32(b_i[15:0]); end
      RCP_F16: begin num32 = F32_ONE;             den32 = f16_to_f32(a_i[15:0]); end
      RCP_F32: begin num32 = F32_ONE;             den32 = a_i[31:0];             end
      default: begin num32 = a_i[31:0];             den32 = b_i[31:0];             end
    endcase

    exp_n = num32[30:23];
    exp_d = den32[30:23];
    sig_n = {(exp_n != 0), num32[22:0]};
    sig_d = {(exp_d != 0), den32[22:0]};

    // Value = sig * 2^(e - 23); normalize subnormal significands so bit 23 is set.
    e_n = ((exp_n == 0) ? 1 : int'(exp_n)) - 127;
    e_d = ((exp_d == 0) ? 1 : int'(exp_d)) - 127;
    msb_n = 0;
    msb_d = 0;
    for (int i = 0; i < 24; i++) begin
      if (sig_n[i]) begin
        msb_n = i;
      end
      if (sig_d[i]) begin
        msb_d = i;
      end
    end
    norm_n = sig_n << (23 - msb_n);
    norm_d = sig_d << (23 - msb_d);
    e_n = e_n - (23 - msb_n);
    e_d = e_d - (23 - msb_d);

    // norm_n * 2^K / norm_d is in (2^(K-1), 2^(K+1)): at least 26 = FracBits+3 bits.
    q_exponent = e_n - e_d - K;
    fp_sign = num32[31] ^ den32[31];
    fp_input_error = (&exp_n) || (&exp_d) || (sig_d == 0);
  end

  // A zero dividend gives a zero with the XOR of the signs.
  fp_round #(.ExpBits(5), .FracBits(10)) u_fdiv_round16 (
    .sign_i(fp_sign),
    .mag_i((sig_n == 0) ? 64'b0 : div_quotient),
    .exponent_i(q_exponent),
    .sticky_i((sig_n != 0) && (div_remainder != 0)),
    .d_o(fdiv16_result),
    .overflow_o(fdiv16_overflow)
  );

  fp_round #(.ExpBits(8), .FracBits(23)) u_fdiv_round32 (
    .sign_i(fp_sign),
    .mag_i((sig_n == 0) ? 64'b0 : div_quotient),
    .exponent_i(q_exponent),
    .sticky_i((sig_n != 0) && (div_remainder != 0)),
    .d_o(fdiv32_result),
    .overflow_o(fdiv32_overflow)
  );

  // ------------------------------------------------------- integer DIVMOD / DIV_RNE
  // Divide magnitudes, then apply signs.
  always_comb begin
    int_signed = !sig_i[0];                         // I32, I64 have even SIGs
    int_wide   = sig_i[1];                          // I64, U64

    if (int_wide) begin
      sign_a = int_signed && a_i[63];
      sign_b = int_signed && b_i[63];
      mag_a = sign_a ? -a_i : a_i;
      mag_b = sign_b ? -b_i : b_i;
      limit_positive = int_signed ? 65'h0_7FFF_FFFF_FFFF_FFFF : 65'h0_FFFF_FFFF_FFFF_FFFF;
      limit_negative = 65'h0_8000_0000_0000_0000;
    end else begin
      sign_a = int_signed && a_i[31];
      sign_b = int_signed && b_i[31];
      mag_a = {32'b0, (sign_a ? -a_i[31:0] : a_i[31:0])};
      mag_b = {32'b0, (sign_b ? -b_i[31:0] : b_i[31:0])};
      limit_positive = int_signed ? 65'h0_0000_0000_7FFF_FFFF : 65'h0_0000_0000_FFFF_FFFF;
      limit_negative = 65'h0_0000_0000_8000_0000;
    end

    quotient_negative = sign_a ^ sign_b;
    mag_q = div_quotient;
    mag_r = div_remainder;

    // Truncated quotient; a nonzero remainder takes A's sign.
    quotient_overflow = quotient_negative ? ({1'b0, mag_q} > limit_negative)
                                          : ({1'b0, mag_q} > limit_positive);
    quotient  = quotient_negative ? -mag_q : mag_q;
    remainder = sign_a ? -mag_r : mag_r;

    // Nearest quotient, ties to even. 2*r is compared without forming q*b.
    round_up = ({mag_r, 1'b0} > {1'b0, mag_b}) ||
               (({mag_r, 1'b0} == {1'b0, mag_b}) && mag_q[0]);
    mag_rne = {1'b0, mag_q} + 65'(round_up);
    rne_overflow = quotient_negative ? (mag_rne > limit_negative) : (mag_rne > limit_positive);
    rne_quotient = quotient_negative ? -mag_rne[63:0] : mag_rne[63:0];

    if (!int_wide) begin
      quotient     = {32'b0, quotient[31:0]};
      remainder    = {32'b0, remainder[31:0]};
      rne_quotient = {32'b0, rne_quotient[31:0]};
    end
  end

  // ------------------------------------------------------------- shared divider
  always_comb begin
    if (fp_div_op) begin
      div_dividend   = {14'b0, norm_n, 26'b0};    // norm_n * 2^K, 50 bits
      div_divisor    = {40'b0, norm_d};
      div_iterations = 7'd50;
    end else begin
      div_dividend   = mag_a;
      div_divisor    = mag_b;
      div_iterations = int_wide ? 7'd64 : 7'd32;
    end
  end

  div_iter #(.Width(64)) u_div (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .start_i(start_i && (fp_div_op || int_div_op)),
    .iterations_i(div_iterations),
    .dividend_i(div_dividend),
    .divisor_i(div_divisor),
    .busy_o(div_busy),
    .finished_o(div_finished),
    .quotient_o(div_quotient),
    .remainder_o(div_remainder)
  );

  // ---------------------------------------------------------------- RSQRT / ExpBits
  // One unit per function serves both formats; F16 inputs widen exactly to F32.
  assign unary_input = f16_op ? f16_to_f32(a_i[15:0]) : a_i[31:0];

  fp_rsqrt u_rsqrt (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .start_i(start_i && rsqrt_op),
    .a_i(unary_input),
    .busy_o(rsqrt_busy),
    .finished_o(rsqrt_finished),
    .d16_o(rsqrt16_result),
    .error16_o(rsqrt16_error),
    .d32_o(rsqrt32_result),
    .error32_o(rsqrt32_error)
  );

  fp_exp u_exp (
    .a_i(unary_input),
    .d16_o(exp16_result),
    .error16_o(exp16_error),
    .d32_o(exp32_result),
    .error32_o(exp32_error)
  );

  // ----------------------------------------------------------------- result mux
  always_comb begin
    if (fp_div_op || int_div_op) begin
      finished_o = div_finished;
    end else if (rsqrt_op) begin
      finished_o = rsqrt_finished;
    end else begin
      finished_o = 1'b1;
    end
  end

  always_comb begin
    result_o = 64'b0;
    result2_o = 64'b0;
    error_o = 1'b0;

    case (sig_i)

      DIV_F16, RCP_F16: begin
        error_o = fp_input_error || fdiv16_overflow;
        result_o = {48'b0, fdiv16_result};
      end

      DIV_F32, RCP_F32: begin
        error_o = fp_input_error || fdiv32_overflow;
        result_o = {32'b0, fdiv32_result};
      end

      // Zero divisor or quotient overflow (signed minimum / -1) faults.
      DIVMOD_I32, DIVMOD_U32, DIVMOD_I64, DIVMOD_U64: begin
        error_o = (mag_b == 0) || quotient_overflow;
        result_o = quotient;
        result2_o = remainder;
      end

      DIV_RNE_I32, DIV_RNE_U32, DIV_RNE_I64, DIV_RNE_U64: begin
        error_o = (mag_b == 0) || rne_overflow;
        result_o = rne_quotient;
      end

      ISQRT_U32: result_o = isqrt64({32'b0, a_i[31:0]});
      ISQRT_U64: result_o = isqrt64(a_i);            // the root always fits U32

      EXP_F16: begin
        error_o = exp16_error;
        result_o = {48'b0, exp16_result};
      end

      EXP_F32: begin
        error_o = exp32_error;
        result_o = {32'b0, exp32_result};
      end

      RSQRT_F16: begin
        error_o = rsqrt16_error;
        result_o = {48'b0, rsqrt16_result};
      end

      RSQRT_F32: begin
        error_o = rsqrt32_error;
        result_o = {32'b0, rsqrt32_result};
      end

      default: error_o = 1'b1;

    endcase

    if (error_o) begin
      result_o = 64'b0;
      result2_o = 64'b0;
    end
  end

endmodule
