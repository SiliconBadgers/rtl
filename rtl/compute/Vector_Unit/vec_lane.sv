// One SIMD lane: operand constants, lane enable and execution units. Register
// values come from register_file; results go back to it through vec_simd, which
// also makes the instruction-wide decisions (legality, commit on any-lane error,
// scalar-once, REDUCE, PERMUTE routing).
module vec_lane #(
  parameter int LaneIndex = 0
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic [2:0]  family_i,
  input  logic [6:0]  sig_i,
  input  logic [4:0]  a_code_i,            // A field: 0-7 V, 8-15 S, 16-19 constants
  input  logic [4:0]  b_code_i,            // B field: same encoding as A
  // C field: numeric (as A), SELECT predicate, or DIVMOD remainder destination
  input  logic [4:0]  c_code_i,
  input  logic [3:0]  a_type_i,            // operand types from vec_decoder
  input  logic [3:0]  b_type_i,
  input  logic [3:0]  c_type_i,
  input  logic [31:0] vl_i,                // active vector length
  input  logic        strict_i,            // 1: saturation is an error
  input  logic        start_i,             // first cycle of a multi-cycle SPECIAL operation

  input  logic [63:0] a_reg_i,             // register_file read of A for this lane (V or S)
  input  logic [63:0] b_reg_i,
  input  logic [63:0] c_reg_i,
  input  logic        pm_bit_i,            // this lane's bit of P[PM] (P0 reads true)
  input  logic        select_bit_i,        // this lane's bit of P[C] (SELECT)
  input  logic [63:0] permute_data_i,      // PERMUTE: A from the lane this lane's B selects

  output logic        enable_o,            // lane is below VL and its PM bit is true
  output logic        finished_o,          // multi-cycle units are done (high for other ops)
  output logic        error_o,             // only raised by enabled lanes
  output logic        saturated_add_o,
  output logic        saturated_sub_o,
  output logic        saturated_product_o,
  output logic        saturated_convert_o,
  output logic        predicate_result_o,
  output logic [63:0] a_value_o,           // operand A (REDUCE input, PERMUTE source)
  output logic [63:0] b_value_o,           // operand B (PERMUTE index)
  output logic [63:0] result_o,
  output logic [63:0] result2_o            // DIVMOD remainder
);

  localparam logic [2:0] FAMILY_ALU     = 3'b001;
  localparam logic [2:0] FAMILY_PRODUCT = 3'b010;
  localparam logic [2:0] FAMILY_CAST    = 3'b100;
  localparam logic [2:0] FAMILY_SPECIAL = 3'b101;
  localparam logic [2:0] FAMILY_DATA    = 3'b110;

  // Operand types (shared with vec_decoder)
  localparam logic [3:0] T_F16   = 4'd0;
  localparam logic [3:0] T_F32   = 4'd1;
  localparam logic [3:0] T_I8    = 4'd2;
  localparam logic [3:0] T_U8    = 4'd3;
  localparam logic [3:0] T_I16   = 4'd4;
  localparam logic [3:0] T_U16   = 4'd5;
  localparam logic [3:0] T_I64   = 4'd8;
  localparam logic [3:0] T_U64   = 4'd9;
  localparam logic [3:0] T_RAW16 = 4'd10;
  localparam logic [3:0] T_RAW64 = 4'd12;

  // DATA
  localparam logic [6:0] COPY16    = 7'd0;
  localparam logic [6:0] COPY32    = 7'd1;
  localparam logic [6:0] COPY64    = 7'd2;
  localparam logic [6:0] PERMUTE16 = 7'd3;
  localparam logic [6:0] PERMUTE32 = 7'd4;
  localparam logic [6:0] PERMUTE64 = 7'd5;
  localparam logic [6:0] IOTA_U32  = 7'd6;

  localparam logic [4:0] K_ZERO     = 5'd16;
  localparam logic [4:0] K_NEG_ZERO = 5'd17;
  localparam logic [4:0] K_ONE      = 5'd18;
  localparam logic [4:0] K_ONES     = 5'd19;

  logic [63:0] a, b, c;

  logic        alu_error, alu_saturated_add, alu_saturated_sub;
  logic [63:0] alu_result;
  logic        product_error, product_saturated;
  logic [63:0] product_result;
  logic        cast_error, cast_saturated;
  logic [63:0] cast_result;
  logic        special_error;
  logic [63:0] special_result, special_result2;
  logic [63:0] data_result;

  // Constants depend on the operand's type.
  function automatic logic [63:0] constant(input logic [4:0] code, input logic [3:0] op_type);
    case (code)
      K_NEG_ZERO: begin
        case (op_type)
          T_F16:   constant = 64'h0000_0000_0000_8000;
          T_F32:   constant = 64'h0000_0000_8000_0000;
          default: constant = 64'b0;
        endcase
      end

      K_ONE: begin
        case (op_type)
          T_F16:   constant = 64'h0000_0000_0000_3C00;
          T_F32:   constant = 64'h0000_0000_3F80_0000;
          default: constant = 64'd1;
        endcase
      end

      // Integer all-ones fills the type's width.
      K_ONES: begin
        case (op_type)
          T_I8, T_U8:                 constant = 64'h0000_0000_0000_00FF;
          T_F16, T_I16, T_U16,
          T_RAW16:                    constant = 64'h0000_0000_0000_FFFF;
          T_I64, T_U64, T_RAW64:      constant = 64'hFFFF_FFFF_FFFF_FFFF;
          default:                    constant = 64'h0000_0000_FFFF_FFFF;
        endcase
      end

      default: constant = 64'b0; // K_ZERO
    endcase
  endfunction

  assign enable_o = (LaneIndex[31:0] < vl_i) && pm_bit_i;

  // Registers come from register_file; constants depend on the operand type.
  // Operand codes 20-31 are rejected by vec_decoder.
  assign a = (a_code_i >= K_ZERO) ? constant(a_code_i, a_type_i) : a_reg_i;
  assign b = (b_code_i >= K_ZERO) ? constant(b_code_i, b_type_i) : b_reg_i;
  assign c = (c_code_i >= K_ZERO) ? constant(c_code_i, c_type_i) : c_reg_i;

  assign a_value_o = a;
  assign b_value_o = b;

  vec_alu u_vec_alu (
    .a_i(a),
    .b_i(b),
    .sig_i(sig_i),
    .select_predicate_i(select_bit_i),
    .strict_i(strict_i),
    .error_o(alu_error),
    .predicate_result_o(predicate_result_o),
    .saturated_add_o(alu_saturated_add),
    .saturated_sub_o(alu_saturated_sub),
    .result_o(alu_result)
  );

  vec_product u_vec_product (
    .a_i(a),
    .b_i(b),
    .c_i(c),
    .sig_i(sig_i),
    .strict_i(strict_i),
    .error_o(product_error),
    .saturated_o(product_saturated),
    .result_o(product_result)
  );

  vec_cast u_vec_cast (
    .a_i(a),
    .b_i(b),
    .sig_i(sig_i),
    .strict_i(strict_i),
    .error_o(cast_error),
    .saturated_o(cast_saturated),
    .result_o(cast_result)
  );

  vec_special u_vec_special (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .start_i(start_i),
    .a_i(a),
    .b_i(b),
    .sig_i(sig_i),
    .finished_o(finished_o),
    .error_o(special_error),
    .result_o(special_result),
    .result2_o(special_result2)
  );

  // DATA: raw moves with no numeric checks. PERMUTE's source comes from vec_simd.
  always_comb begin
    case (sig_i)
      COPY16:    data_result = {48'b0, a[15:0]};
      COPY32:    data_result = {32'b0, a[31:0]};
      COPY64:    data_result = a;
      PERMUTE16: data_result = {48'b0, permute_data_i[15:0]};
      PERMUTE32: data_result = {32'b0, permute_data_i[31:0]};
      PERMUTE64: data_result = permute_data_i;
      IOTA_U32:  data_result = {32'b0, LaneIndex[31:0]};
      default:   data_result = 64'b0;
    endcase
  end

  always_comb begin
    result2_o = 64'b0;
    case (family_i)
      FAMILY_PRODUCT: begin
        result_o = product_result;
        error_o = enable_o && product_error;
      end

      FAMILY_CAST: begin
        result_o = cast_result;
        error_o = enable_o && cast_error;
      end

      FAMILY_SPECIAL: begin
        result_o = special_result;
        result2_o = special_result2;
        error_o = enable_o && special_error;
      end

      FAMILY_DATA: begin
        // PERMUTE index errors are checked in vec_simd.
        result_o = data_result;
        error_o = 1'b0;
      end

      FAMILY_ALU: begin
        result_o = alu_result;
        error_o = enable_o && alu_error;
      end

      default: begin // CONTROL and REDUCE are handled in vec_simd.
        result_o = 64'b0;
        error_o = 1'b0;
      end
    endcase
  end

  // Disabled lanes perform no error check or counter update.
  assign saturated_add_o     = enable_o && (family_i == FAMILY_ALU) && alu_saturated_add;
  assign saturated_sub_o     = enable_o && (family_i == FAMILY_ALU) && alu_saturated_sub;
  assign saturated_product_o = enable_o && (family_i == FAMILY_PRODUCT) && product_saturated;
  assign saturated_convert_o = enable_o && (family_i == FAMILY_CAST) && cast_saturated;

endmodule
