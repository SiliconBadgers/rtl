module vec_alu (
  input  logic [63:0] a_i,
  input  logic [63:0] b_i,
  input  logic [ 6:0] sig_i,
  input  logic        select_predicate_i,
  input  logic        strict_i,            // 1: saturation is an error, 0: write clamped value
  output logic        error_o,
  output logic        predicate_result_o,
  output logic        saturated_add_o,     // ADD_SAT clamped
  output logic        saturated_sub_o,     // SUB_SAT clamped
  output logic [63:0] result_o
);

  // ALU SIG encodings (Signatures sheet, SIG = FN*8 + TYPE)
  localparam logic [6:0] ADD_F16 = 7'b000_0000;
  localparam logic [6:0] ADD_F32 = 7'b000_0001;
  localparam logic [6:0] ADD_I32 = 7'b000_0010;
  localparam logic [6:0] ADD_U32 = 7'b000_0011;
  localparam logic [6:0] ADD_I64 = 7'b000_0100;
  localparam logic [6:0] ADD_U64 = 7'b000_0101;

  localparam logic [6:0] SUB_F16 = 7'b000_1000;
  localparam logic [6:0] SUB_F32 = 7'b000_1001;
  localparam logic [6:0] SUB_I32 = 7'b000_1010;
  localparam logic [6:0] SUB_U32 = 7'b000_1011;
  localparam logic [6:0] SUB_I64 = 7'b000_1100;
  localparam logic [6:0] SUB_U64 = 7'b000_1101;

  localparam logic [6:0] EQ_F16 = 7'b001_0000;
  localparam logic [6:0] EQ_F32 = 7'b001_0001;
  localparam logic [6:0] EQ_I32 = 7'b001_0010;
  localparam logic [6:0] EQ_U32 = 7'b001_0011;
  localparam logic [6:0] EQ_I64 = 7'b001_0100;
  localparam logic [6:0] EQ_U64 = 7'b001_0101;

  localparam logic [6:0] LT_F16 = 7'b001_1000;
  localparam logic [6:0] LT_F32 = 7'b001_1001;
  localparam logic [6:0] LT_I32 = 7'b001_1010;
  localparam logic [6:0] LT_U32 = 7'b001_1011;
  localparam logic [6:0] LT_I64 = 7'b001_1100;
  localparam logic [6:0] LT_U64 = 7'b001_1101;

  localparam logic [6:0] SELECT_F16 = 7'b010_0000;
  localparam logic [6:0] SELECT_F32 = 7'b010_0001;
  localparam logic [6:0] SELECT_I32 = 7'b010_0010;
  localparam logic [6:0] SELECT_U32 = 7'b010_0011;
  localparam logic [6:0] SELECT_I64 = 7'b010_0100;
  localparam logic [6:0] SELECT_U64 = 7'b010_0101;

  localparam logic [6:0] AND_I32 = 7'b010_1010;
  localparam logic [6:0] AND_U32 = 7'b010_1011;
  localparam logic [6:0] AND_I64 = 7'b010_1100;
  localparam logic [6:0] AND_U64 = 7'b010_1101;

  localparam logic [6:0] XOR_I32 = 7'b011_0010;
  localparam logic [6:0] XOR_U32 = 7'b011_0011;
  localparam logic [6:0] XOR_I64 = 7'b011_0100;
  localparam logic [6:0] XOR_U64 = 7'b011_0101;

  localparam logic [6:0] SHL_I32 = 7'b011_1010;
  localparam logic [6:0] SHL_U32 = 7'b011_1011;
  localparam logic [6:0] SHL_I64 = 7'b011_1100;
  localparam logic [6:0] SHL_U64 = 7'b011_1101;

  localparam logic [6:0] SHR_I32 = 7'b100_0010;
  localparam logic [6:0] SHR_U32 = 7'b100_0011;
  localparam logic [6:0] SHR_I64 = 7'b100_0100;
  localparam logic [6:0] SHR_U64 = 7'b100_0101;

  localparam logic [6:0] CLZ_I32 = 7'b100_1010;
  localparam logic [6:0] CLZ_U32 = 7'b100_1011;
  localparam logic [6:0] CLZ_I64 = 7'b100_1100;
  localparam logic [6:0] CLZ_U64 = 7'b100_1101;

  localparam logic [6:0] ADD_SAT_I32 = 7'b101_0010;
  localparam logic [6:0] ADD_SAT_I64 = 7'b101_0100;

  localparam logic [6:0] SUB_SAT_I32 = 7'b101_1010;
  localparam logic [6:0] SUB_SAT_I64 = 7'b101_1100;

  localparam logic [6:0] RSHIFT_RNE_I32 = 7'b110_0010;
  localparam logic [6:0] RSHIFT_RNE_I64 = 7'b110_0100;

  logic overflow;
  logic [64:0] wide_result;
  logic [15:0] fp16_result;
  logic [31:0] fp32_result;

  logic sub;

  logic eq_result;
  logic lt_result;
  logic eq_error, lt_error;

  integer i;
  logic found;
  logic [6:0] clz_count;

  logic [63:0] rne_shifted;
  logic rne_half, rne_sticky, rne_round;

  assign sub = sig_i[3];

  fp16_addsub u_fp16_addsub (
    .a_i  (a_i[15:0]),
    .b_i  (b_i[15:0]),
    .sub_i(sub),
    .d_o  (fp16_result)
  );

  fp32_addsub u_fp32_addsub (
    .a_i  (a_i[31:0]),
    .b_i  (b_i[31:0]),
    .sub_i(sub),
    .d_o  (fp32_result)
  );

  alu_eq u_alu_eq (
    .a_i(a_i),
    .b_i(b_i),
    .sig_i(sig_i),
    .eq_o(eq_result),
    .error_o(eq_error)
  );

  alu_lt u_lt (
    .a_i(a_i),
    .b_i(b_i),
    .sig_i(sig_i),
    .lt_o(lt_result),
    .error_o(lt_error)
  );

  always_comb begin
    result_o = 64'b0;
    error_o = 1'b0;
    wide_result = 65'b0;
    predicate_result_o = 1'b0;
    clz_count = 7'b0;
    found = 1'b0;
    overflow = 1'b0;
    saturated_add_o = 1'b0;
    saturated_sub_o = 1'b0;
    rne_shifted = 64'b0;
    rne_half = 1'b0;
    rne_sticky = 1'b0;
    rne_round = 1'b0;

    case (sig_i)

      ADD_F16, SUB_F16: begin
        // ADD.F16 / SUB.F16: inputs and result must be finite
        error_o = (&a_i[14:10]) || (&b_i[14:10]) || (&fp16_result[14:10]);
        if (!error_o) begin
          result_o = {48'b0, fp16_result};
        end
      end

      ADD_F32, SUB_F32: begin
        // ADD.F32 / SUB.F32: inputs and result must be finite
        error_o = (&a_i[30:23]) || (&b_i[30:23]) || (&fp32_result[30:23]);
        if (!error_o) begin
          result_o = {32'b0, fp32_result};
        end
      end

      ADD_I32, SUB_I32: begin
        // ADD.I32 / SUB.I32
        if (sub) begin
          wide_result = {33'b0, a_i[31:0]} - {33'b0, b_i[31:0]};
        end else begin
          wide_result = {33'b0, a_i[31:0]} + {33'b0, b_i[31:0]};
        end

        error_o = sub ? ((a_i[31] != b_i[31]) && (a_i[31] != wide_result[31])) :
                      ((a_i[31] == b_i[31]) && (a_i[31] != wide_result[31]));

        if (!error_o) begin
          result_o = {32'b0, wide_result[31:0]};
        end
      end

      ADD_U32, SUB_U32: begin
        // ADD.U32 / SUB.U32
        if (sub) begin
          wide_result = {33'b0, a_i[31:0]} - {33'b0, b_i[31:0]};
        end else begin
          wide_result = {33'b0, a_i[31:0]} + {33'b0, b_i[31:0]};
        end

        error_o = sub ? (a_i[31:0] < b_i[31:0]) : wide_result[32];

        if (!error_o) begin
          result_o = {32'b0, wide_result[31:0]};
        end
      end

      ADD_I64, SUB_I64: begin
        // ADD.I64 / SUB.I64
        if (sub) begin
          wide_result = {1'b0, a_i} - {1'b0, b_i};
        end else begin
          wide_result = {1'b0, a_i} + {1'b0, b_i};
        end

        error_o = sub ? ((a_i[63] != b_i[63]) && (a_i[63] != wide_result[63])) :
                      ((a_i[63] == b_i[63]) && (a_i[63] != wide_result[63]));

        if (!error_o) begin
          result_o = wide_result[63:0];
        end
      end

      ADD_U64, SUB_U64: begin
        // ADD.U64 / SUB.U64
        if (sub) begin
          wide_result = {1'b0, a_i} - {1'b0, b_i};
        end else begin
          wide_result = {1'b0, a_i} + {1'b0, b_i};
        end

        error_o = sub ? (a_i < b_i) : wide_result[64];

        if (!error_o) begin
          result_o = wide_result[63:0];
        end
      end

      EQ_F16, EQ_F32, EQ_I32, EQ_U32, EQ_I64, EQ_U64: begin
        error_o = eq_error;
        predicate_result_o = !error_o && eq_result;
      end

      LT_F16, LT_F32, LT_I32, LT_U32, LT_I64, LT_U64: begin
        error_o = lt_error;
        predicate_result_o = !error_o && lt_result;
      end

      // SELECT.F16: both alternatives must be finite
      SELECT_F16: begin
        error_o = (&a_i[14:10]) || (&b_i[14:10]);
        if (!error_o) begin
          result_o = {48'b0, (select_predicate_i ? a_i[15:0] : b_i[15:0])};
        end
      end

      // SELECT.F32: both alternatives must be finite
      SELECT_F32: begin
        error_o = (&a_i[30:23]) || (&b_i[30:23]);
        if (!error_o) begin
          result_o = {32'b0, (select_predicate_i ? a_i[31:0] : b_i[31:0])};
        end
      end

      // SELECT.I32 / SELECT.U32
      SELECT_I32, SELECT_U32: begin
        result_o = {32'b0, (select_predicate_i ? a_i[31:0] : b_i[31:0])};
      end

      // SELECT.I64 / SELECT.U64
      SELECT_I64, SELECT_U64: begin
        result_o = select_predicate_i ? a_i : b_i;
      end

      // AND.I32 / AND.U32
      AND_I32, AND_U32: begin
        result_o = {32'b0, (a_i[31:0] & b_i[31:0])};
      end

      // AND.I64 / AND.U64
      AND_I64, AND_U64: begin
        result_o = a_i & b_i;
      end

      // XOR.I32 / XOR.U32
      XOR_I32, XOR_U32: begin
        result_o = {32'b0, (a_i[31:0] ^ b_i[31:0])};
      end

      // XOR.I64 / XOR.U64
      XOR_I64, XOR_U64: begin
        result_o = a_i ^ b_i;
      end

      // SHL.I32 / SHL.U32
      SHL_I32, SHL_U32: begin
        if (b_i[31:0] >= 32) begin
          result_o = 64'b0;
        end else begin
          result_o = {32'b0, (a_i[31:0] << b_i[31:0])};
        end
      end

      // SHL.I64 / SHL.U64
      SHL_I64, SHL_U64: begin
        if (b_i[31:0] >= 64) begin
          result_o = 64'b0;
        end else begin
          result_o = a_i << b_i[31:0];
        end
      end

      // SHR.I32 (arithmetic right shift)
      SHR_I32: begin
        if (b_i[31:0] >= 32) begin
          result_o = a_i[31] ? {32'b0, 32'hFFFFFFFF} : 64'b0;
        end else begin
          result_o = {32'b0, ($signed(a_i[31:0]) >>> b_i[31:0])};
        end
      end

      // SHR.U32 (logical right shift)
      SHR_U32: begin
        if (b_i[31:0] >= 32) begin
          result_o = 64'b0;
        end else begin
          result_o = {32'b0, (a_i[31:0] >> b_i[31:0])};
        end
      end

      // SHR.I64 (arithmetic right shift)
      SHR_I64: begin
        if (b_i[31:0] >= 64) begin
          result_o = a_i[63] ? 64'hFFFFFFFFFFFFFFFF : 64'b0;
        end else begin
          result_o = $signed(a_i) >>> b_i[31:0];
        end
      end

      // SHR.U64 (logical right shift)
      SHR_U64: begin
        if (b_i[31:0] >= 64) begin
          result_o = 64'b0;
        end else begin
          result_o = a_i >> b_i[31:0];
        end
      end

      CLZ_I32, CLZ_U32: begin
        // CLZ I32 / CLZ U32
        for (i = 31; i >= 0; i = i - 1) begin
          if (!found) begin
            if (a_i[i] == 1'b0) begin
              clz_count = clz_count + 1;
            end else begin
              found = 1;
            end
          end
        end
        result_o = {57'b0, clz_count};
      end

      CLZ_I64, CLZ_U64: begin
        // CLZ I64 / CLZ U64
        for (i = 63; i >= 0; i = i - 1) begin
          if (!found) begin
            if (a_i[i] == 1'b0) begin
              clz_count = clz_count + 1;
            end else begin
              found = 1;
            end
          end
        end
        result_o = {57'b0, clz_count};
      end

      ADD_SAT_I32, SUB_SAT_I32: begin
        // ADD_SAT.I32 / SUB_SAT.I32
        if (sub) begin
          wide_result = {33'b0, a_i[31:0]} - {33'b0, b_i[31:0]};
        end else begin
          wide_result = {33'b0, a_i[31:0]} + {33'b0, b_i[31:0]};
        end

        overflow = sub ? ((a_i[31] != b_i[31]) && (a_i[31] != wide_result[31])) :
                         ((a_i[31] == b_i[31]) && (a_i[31] != wide_result[31]));
        saturated_add_o = overflow && !sub;
        saturated_sub_o = overflow && sub;
        error_o = overflow && strict_i;

        // Overflow direction follows the sign of A.
        if (!error_o) begin
          result_o = overflow ? {32'b0, (a_i[31] ? 32'h8000_0000 : 32'h7FFF_FFFF)} :
                              {32'b0, wide_result[31:0]};
        end
      end

      ADD_SAT_I64, SUB_SAT_I64: begin
        // ADD_SAT.I64 / SUB_SAT.I64
        if (sub) begin
          wide_result = {1'b0, a_i} - {1'b0, b_i};
        end else begin
          wide_result = {1'b0, a_i} + {1'b0, b_i};
        end

        overflow = sub ? ((a_i[63] != b_i[63]) && (a_i[63] != wide_result[63])) :
                         ((a_i[63] == b_i[63]) && (a_i[63] != wide_result[63]));
        saturated_add_o = overflow && !sub;
        saturated_sub_o = overflow && sub;
        error_o = overflow && strict_i;

        if (!error_o) begin
          result_o = overflow ? (a_i[63] ? 64'h8000_0000_0000_0000 : 64'h7FFF_FFFF_FFFF_FFFF) :
                              wide_result[63:0];
        end
      end

      // RSHIFT_RNE.I32: A / 2^B rounded to nearest, ties to even
      RSHIFT_RNE_I32: begin
        if (b_i[31:0] >= 32) begin
          // |A| / 2^32 is at most 0.5, which ties to 0.
          result_o = 64'b0;
        end else if (b_i[31:0] == 0) begin
          result_o = {32'b0, a_i[31:0]};
        end else begin
          rne_shifted = {32'b0, ($signed(a_i[31:0]) >>> b_i[4:0])};
          rne_half = a_i[6'(b_i[4:0]-5'd1)];
          rne_sticky = |(a_i[31:0] & ((32'd1 << (b_i[4:0] - 5'd1)) - 32'd1));
          rne_round = rne_half && (rne_sticky || rne_shifted[0]);
          result_o = {32'b0, (rne_shifted[31:0] + {31'b0, rne_round})};
        end
      end

      // RSHIFT_RNE.I64: A / 2^B rounded to nearest, ties to even
      RSHIFT_RNE_I64: begin
        if (b_i[31:0] >= 64) begin
          // |A| / 2^64 is at most 0.5, which ties to 0.
          result_o = 64'b0;
        end else if (b_i[31:0] == 0) begin
          result_o = a_i;
        end else begin
          rne_shifted = $signed(a_i) >>> b_i[5:0];
          rne_half = a_i[b_i[5:0]-6'd1];
          rne_sticky = |(a_i & ((64'd1 << (b_i[5:0] - 6'd1)) - 64'd1));
          rne_round = rne_half && (rne_sticky || rne_shifted[0]);
          result_o = rne_shifted + {63'b0, rne_round};
        end
      end

      default: begin
        error_o = 1'b1;
        predicate_result_o = 1'b0;
        result_o = 64'b0;
      end

    endcase
  end

endmodule
