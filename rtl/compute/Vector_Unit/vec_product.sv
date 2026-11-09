// PRODUCT family: FMA (F16, F32, F16->F32), WMAC, MULSHIFT, MUL_CHECK.
// Every product is formed exactly before it is rounded, checked, or clamped.
module vec_product (
  input  logic [63:0] a_i,
  input  logic [63:0] b_i,
  input  logic [63:0] c_i,          // FMA/WMAC addend, MULSHIFT shift count
  input  logic [ 6:0] sig_i,
  input  logic        strict_i,     // 1: saturation is an error, 0: write clamped value
  output logic        error_o,
  output logic        saturated_o,  // MULSHIFT clamped (product stage)
  output logic [63:0] result_o
);

  // PRODUCT SIG encodings (Signatures sheet)
  localparam logic [6:0] FMA_F16 = 7'b000_0000;
  localparam logic [6:0] FMA_F32 = 7'b000_0001;
  localparam logic [6:0] FMA_F16_F32 = 7'b000_0010;
  localparam logic [6:0] WMAC_I16_I32 = 7'b000_0011;
  localparam logic [6:0] WMAC_I32_I64 = 7'b000_0100;
  localparam logic [6:0] MULSHIFT_I32_I16 = 7'b000_0101;
  localparam logic [6:0] MULSHIFT_I32_U16 = 7'b000_0110;
  localparam logic [6:0] MUL_CHECK_I64 = 7'b000_0111;
  localparam logic [6:0] MUL_CHECK_U64 = 7'b000_1000;

  localparam logic signed [63:0] I32_MAX = 64'sd2147483647;
  localparam logic signed [63:0] I32_MIN = -64'sd2147483648;

  logic [15:0] fma_f16_result;
  logic [31:0] fma_f32_result;
  logic [31:0] fma_f16_f32_result;
  logic fma_f16_error, fma_f32_error, fma_f16_f32_error;

  logic signed [33:0] wmac32;  // I16*I16 + I32, exact
  logic signed [65:0] wmac64;  // I32*I32 + I64, exact
  logic signed [63:0] mulshift_product;
  logic signed [63:0] mulshift_shifted, mulshift_rounded;
  logic mulshift_half, mulshift_sticky, mulshift_round, mulshift_overflow;
  logic signed [127:0] mul_signed;
  logic        [127:0] mul_unsigned;

  fp_fma #(
    .AbExpBits (5),
    .AbFracBits(10),
    .CdExpBits (5),
    .CdFracBits(10)
  ) u_fma_f16 (
    .a_i(a_i[15:0]),
    .b_i(b_i[15:0]),
    .c_i(c_i[15:0]),
    .d_o(fma_f16_result),
    .error_o(fma_f16_error)
  );

  fp_fma #(
    .AbExpBits (8),
    .AbFracBits(23),
    .CdExpBits (8),
    .CdFracBits(23)
  ) u_fma_f32 (
    .a_i(a_i[31:0]),
    .b_i(b_i[31:0]),
    .c_i(c_i[31:0]),
    .d_o(fma_f32_result),
    .error_o(fma_f32_error)
  );

  // F16 A/B, F32 C/D
  fp_fma #(
    .AbExpBits (5),
    .AbFracBits(10),
    .CdExpBits (8),
    .CdFracBits(23)
  ) u_fma_f16_f32 (
    .a_i(a_i[15:0]),
    .b_i(b_i[15:0]),
    .c_i(c_i[31:0]),
    .d_o(fma_f16_f32_result),
    .error_o(fma_f16_f32_error)
  );

  always_comb begin
    result_o = 64'b0;
    error_o = 1'b0;
    saturated_o = 1'b0;

    wmac32 = '0;
    wmac64 = '0;
    mulshift_product = '0;
    mulshift_shifted = '0;
    mulshift_rounded = '0;
    mulshift_half = 1'b0;
    mulshift_sticky = 1'b0;
    mulshift_round = 1'b0;
    mulshift_overflow = 1'b0;
    mul_signed = '0;
    mul_unsigned = '0;

    case (sig_i)

      FMA_F16: begin
        error_o = fma_f16_error;
        if (!error_o) begin
          result_o = {48'b0, fma_f16_result};
        end
      end

      FMA_F32: begin
        error_o = fma_f32_error;
        if (!error_o) begin
          result_o = {32'b0, fma_f32_result};
        end
      end

      FMA_F16_F32: begin
        error_o = fma_f16_f32_error;
        if (!error_o) begin
          result_o = {32'b0, fma_f16_f32_result};
        end
      end

      // WMAC.I16_I32: D = A*B + C exactly; error if it does not fit I32.
      WMAC_I16_I32: begin
        wmac32 = $signed({{18{a_i[15]}}, a_i[15:0]}) * $signed({{18{b_i[15]}}, b_i[15:0]}) +
          $signed({{2{c_i[31]}}, c_i[31:0]});
        error_o = (wmac32 > 34'sd2147483647) || (wmac32 < -34'sd2147483648);
        if (!error_o) begin
          result_o = {32'b0, wmac32[31:0]};
        end
      end

      // WMAC.I32_I64: D = A*B + C exactly; error if it does not fit I64.
      WMAC_I32_I64: begin
        wmac64 = $signed({{34{a_i[31]}}, a_i[31:0]}) * $signed({{34{b_i[31]}}, b_i[31:0]}) +
          $signed({{2{c_i[63]}}, c_i});
        error_o = (wmac64[65:63] != 3'b000) && (wmac64[65:63] != 3'b111);
        if (!error_o) begin
          result_o = wmac64[63:0];
        end
      end

      // MULSHIFT: exact 48-bit product, divide by 2^C with ties to even, clamp to I32.
      MULSHIFT_I32_I16, MULSHIFT_I32_U16: begin
        if (sig_i == MULSHIFT_I32_I16) begin
          mulshift_product = $signed({{32{a_i[31]}}, a_i[31:0]}) *
            $signed({{48{b_i[15]}}, b_i[15:0]});
        end else begin
          mulshift_product = $signed({{32{a_i[31]}}, a_i[31:0]}) * $signed({48'b0, b_i[15:0]});
        end

        if (c_i[31:0] > 32'd63) begin
          // Shift counts are limited to 0-63.
          error_o = 1'b1;
        end else begin
          if (c_i[5:0] == 6'd0) begin
            mulshift_rounded = mulshift_product;
          end else begin
            // |product| < 2^47, so a 64-bit arithmetic shift covers every count.
            mulshift_shifted = mulshift_product >>> c_i[5:0];
            mulshift_half = mulshift_product[c_i[5:0]-6'd1];
            mulshift_sticky = |(mulshift_product & ((64'sd1 <<< (c_i[5:0] - 6'd1)) - 64'sd1));
            mulshift_round = mulshift_half && (mulshift_sticky || mulshift_shifted[0]);
            mulshift_rounded = mulshift_shifted + $signed({63'b0, mulshift_round});
          end

          mulshift_overflow = (mulshift_rounded > I32_MAX) || (mulshift_rounded < I32_MIN);
          saturated_o = mulshift_overflow;
          error_o = mulshift_overflow && strict_i;

          if (!error_o) begin
            if (mulshift_rounded > I32_MAX) begin
              result_o = {32'b0, 32'h7FFF_FFFF};
            end else if (mulshift_rounded < I32_MIN) begin
              result_o = {32'b0, 32'h8000_0000};
            end else begin
              result_o = {32'b0, mulshift_rounded[31:0]};
            end
          end
        end
      end

      // MUL_CHECK.I64: exact 128-bit product; error if it does not fit I64.
      MUL_CHECK_I64: begin
        mul_signed = $signed({{64{a_i[63]}}, a_i}) * $signed({{64{b_i[63]}}, b_i});
        error_o = (mul_signed[127:63] != {65{1'b0}}) && (mul_signed[127:63] != {65{1'b1}});
        if (!error_o) begin
          result_o = mul_signed[63:0];
        end
      end

      // MUL_CHECK.U64: exact 128-bit product; error if it does not fit U64.
      MUL_CHECK_U64: begin
        mul_unsigned = {64'b0, a_i} * {64'b0, b_i};
        error_o = (mul_unsigned[127:64] != 64'b0);
        if (!error_o) begin
          result_o = mul_unsigned[63:0];
        end
      end

      default: begin
        error_o  = 1'b1;
        result_o = 64'b0;
      end

    endcase
  end

endmodule
