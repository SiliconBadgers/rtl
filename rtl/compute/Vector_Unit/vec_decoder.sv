// Command decoder: splits the 32-bit word, gives each operand its type, and rejects
// illegal commands before any lane writes.
// Word: FAMILY[31:29] | SIG[28:22] | D[21:18] | A[17:13] | B[12:8] | C[7:3] | PM[2:0]
module vec_decoder (
  input  logic [31:0] command_i,
  output logic [2:0]  family_o,
  output logic [6:0]  sig_o,
  output logic [3:0]  d_code_o,
  output logic [4:0]  a_code_o,
  output logic [4:0]  b_code_o,
  output logic [4:0]  c_code_o,
  output logic [2:0]  pm_o,
  output logic [3:0]  a_type_o,            // operand types, used for type-dependent constants
  output logic [3:0]  b_type_o,
  output logic [3:0]  c_type_o,
  output logic        is_control_o,
  output logic        is_alu_o,
  output logic        is_product_o,
  output logic        is_reduce_o,
  output logic        is_cast_o,
  output logic        is_special_o,
  output logic        is_data_o,
  output logic        predicate_dest_o,    // ALU result is a predicate written to P[D]
  output logic        scalar_dest_o,       // numeric result is written to S[D-8] (not REDUCE)
  output logic        second_dest_o,       // DIVMOD: the remainder is written to C
  output logic        multi_cycle_o,       // DIV, RCP, DIVMOD, DIV_RNE, RSQRT: sequential units
  output logic        illegal_o
);

  localparam logic [2:0] FAMILY_CONTROL = 3'b000;
  localparam logic [2:0] FAMILY_ALU     = 3'b001;
  localparam logic [2:0] FAMILY_PRODUCT = 3'b010;
  localparam logic [2:0] FAMILY_REDUCE  = 3'b011;
  localparam logic [2:0] FAMILY_CAST    = 3'b100;
  localparam logic [2:0] FAMILY_SPECIAL = 3'b101;
  localparam logic [2:0] FAMILY_DATA    = 3'b110;

  // Operand types (shared with vec_lane)
  localparam logic [3:0] T_F16   = 4'd0;
  localparam logic [3:0] T_F32   = 4'd1;
  localparam logic [3:0] T_I8    = 4'd2;
  localparam logic [3:0] T_U8    = 4'd3;
  localparam logic [3:0] T_I16   = 4'd4;
  localparam logic [3:0] T_U16   = 4'd5;
  localparam logic [3:0] T_I32   = 4'd6;
  localparam logic [3:0] T_U32   = 4'd7;
  localparam logic [3:0] T_I64   = 4'd8;
  localparam logic [3:0] T_U64   = 4'd9;
  localparam logic [3:0] T_RAW16 = 4'd10;
  localparam logic [3:0] T_RAW32 = 4'd11;
  localparam logic [3:0] T_RAW64 = 4'd12;
  localparam logic [3:0] T_NONE  = 4'd15;

  // CONTROL
  localparam logic [6:0] SETVL = 7'd0;
  localparam logic [6:0] PAND  = 7'd1;
  localparam logic [6:0] PNOT  = 7'd2;

  // PRODUCT
  localparam logic [6:0] FMA_F16          = 7'd0;
  localparam logic [6:0] FMA_F32          = 7'd1;
  localparam logic [6:0] FMA_F16_F32      = 7'd2;
  localparam logic [6:0] WMAC_I16_I32     = 7'd3;
  localparam logic [6:0] WMAC_I32_I64     = 7'd4;
  localparam logic [6:0] MULSHIFT_I32_I16 = 7'd5;
  localparam logic [6:0] MULSHIFT_I32_U16 = 7'd6;
  localparam logic [6:0] MUL_CHECK_I64    = 7'd7;
  localparam logic [6:0] MUL_CHECK_U64    = 7'd8;

  // SPECIAL
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
  localparam logic [4:0] K_ONES     = 5'd19;

  logic [3:0] fn;
  logic [2:0] alu_type;
  logic select_op, clz_op, shift_op;
  logic legal_sig;
  logic uses_b, uses_c;                  // B / C are numeric inputs
  logic d_scalar;

  // ALU TYPE field -> operand type
  function automatic logic [3:0] alu_operand_type(input logic [2:0] t);
    case (t)
      3'd0:    alu_operand_type = T_F16;
      3'd1:    alu_operand_type = T_F32;
      3'd2:    alu_operand_type = T_I32;
      3'd3:    alu_operand_type = T_U32;
      3'd4:    alu_operand_type = T_I64;
      default: alu_operand_type = T_U64;
    endcase
  endfunction

  // CAST type number -> operand type
  function automatic logic [3:0] cast_operand_type(input logic [2:0] t);
    case (t)
      3'd0:    cast_operand_type = T_F16;
      3'd1:    cast_operand_type = T_F32;
      3'd2:    cast_operand_type = T_I8;
      3'd3:    cast_operand_type = T_U8;
      3'd4:    cast_operand_type = T_I16;
      3'd5:    cast_operand_type = T_U16;
      3'd6:    cast_operand_type = T_I32;
      default: cast_operand_type = T_I64;
    endcase
  endfunction

  // A numeric operand: a V/S register or a constant that suits the type.
  function automatic logic operand_ok(input logic [4:0] code, input logic [3:0] t);
    logic fp;
    fp = (t == T_F16) || (t == T_F32);
    operand_ok = (t != T_NONE) &&
                 (code <= K_ONES) &&
                 !((code == K_NEG_ZERO) && !fp) &&   // floating negative zero
                 !((code == K_ONES) && fp);          // integer all-ones
  endfunction

  assign family_o = command_i[31:29];
  assign sig_o    = command_i[28:22];
  assign d_code_o = command_i[21:18];
  assign a_code_o = command_i[17:13];
  assign b_code_o = command_i[12:8];
  assign c_code_o = command_i[7:3];
  assign pm_o     = command_i[2:0];

  // ALU SIG = FN*8 + TYPE
  assign fn       = sig_o[6:3];
  assign alu_type = sig_o[2:0];

  assign is_control_o = (family_o == FAMILY_CONTROL);
  assign is_alu_o     = (family_o == FAMILY_ALU);
  assign is_product_o = (family_o == FAMILY_PRODUCT);
  assign is_reduce_o  = (family_o == FAMILY_REDUCE);
  assign is_cast_o    = (family_o == FAMILY_CAST);
  assign is_special_o = (family_o == FAMILY_SPECIAL);
  assign is_data_o    = (family_o == FAMILY_DATA);

  assign select_op = (fn == 4'd4);
  assign clz_op    = (fn == 4'd9);
  assign shift_op  = (fn == 4'd7) || (fn == 4'd8) || (fn == 4'd12);   // SHL SHR RSHIFT_RNE

  assign d_scalar       = d_code_o[3];
  assign predicate_dest_o = is_alu_o && ((fn == 4'd2) || (fn == 4'd3)); // EQ / LT
  assign second_dest_o    = is_special_o && (sig_o >= DIVMOD_I32) && (sig_o <= DIVMOD_U64);
  assign multi_cycle_o    = is_special_o && ((sig_o <= DIV_RNE_U64) ||
                                             (sig_o == RSQRT_F16) || (sig_o == RSQRT_F32));
  assign scalar_dest_o    = d_scalar && !predicate_dest_o &&
                          (is_alu_o || is_product_o || is_cast_o || is_special_o || is_data_o);

  // Operand types per signature (Signatures sheet).
  always_comb begin
    a_type_o = T_NONE;
    b_type_o = T_NONE;
    c_type_o = T_NONE;

    case (family_o)
      FAMILY_ALU: begin
        a_type_o = alu_operand_type(alu_type);
        b_type_o = clz_op ? T_NONE : (shift_op ? T_U32 : alu_operand_type(alu_type));
      end

      FAMILY_PRODUCT: begin
        case (sig_o)
          FMA_F16:          begin a_type_o = T_F16; b_type_o = T_F16; c_type_o = T_F16; end
          FMA_F32:          begin a_type_o = T_F32; b_type_o = T_F32; c_type_o = T_F32; end
          FMA_F16_F32:      begin a_type_o = T_F16; b_type_o = T_F16; c_type_o = T_F32; end
          WMAC_I16_I32:     begin a_type_o = T_I16; b_type_o = T_I16; c_type_o = T_I32; end
          WMAC_I32_I64:     begin a_type_o = T_I32; b_type_o = T_I32; c_type_o = T_I64; end
          MULSHIFT_I32_I16: begin a_type_o = T_I32; b_type_o = T_I16; c_type_o = T_U32; end
          MULSHIFT_I32_U16: begin a_type_o = T_I32; b_type_o = T_U16; c_type_o = T_U32; end
          MUL_CHECK_I64:    begin a_type_o = T_I64; b_type_o = T_I64; end
          MUL_CHECK_U64:    begin a_type_o = T_U64; b_type_o = T_U64; end
          default: ;
        endcase
      end

      FAMILY_REDUCE: begin
        // SUM: F16 F32 I32 I64 U32 U64; MAX/MIN: F16 F32 I32 U32 I64 U64
        case (sig_o)
          7'd0, 7'd6, 7'd12:  a_type_o = T_F16;
          7'd1, 7'd7, 7'd13:  a_type_o = T_F32;
          7'd2, 7'd8, 7'd14:  a_type_o = T_I32;
          7'd3, 7'd10, 7'd16: a_type_o = T_I64;
          7'd4, 7'd9, 7'd15:  a_type_o = T_U32;
          7'd5, 7'd11, 7'd17: a_type_o = T_U64;
          default: ;
        endcase
      end

      FAMILY_CAST: begin
        a_type_o = cast_operand_type(sig_o[5:3]);
        b_type_o = T_I32;                          // exponent e
      end

      FAMILY_SPECIAL: begin
        case (sig_o)
          DIV_F16:                 begin a_type_o = T_F16; b_type_o = T_F16; end
          DIV_F32:                 begin a_type_o = T_F32; b_type_o = T_F32; end
          RCP_F16, EXP_F16,
          RSQRT_F16:               a_type_o = T_F16;
          RCP_F32, EXP_F32,
          RSQRT_F32:               a_type_o = T_F32;
          DIVMOD_I32, DIV_RNE_I32: begin a_type_o = T_I32; b_type_o = T_I32; end
          DIVMOD_U32, DIV_RNE_U32: begin a_type_o = T_U32; b_type_o = T_U32; end
          DIVMOD_I64, DIV_RNE_I64: begin a_type_o = T_I64; b_type_o = T_I64; end
          DIVMOD_U64, DIV_RNE_U64: begin a_type_o = T_U64; b_type_o = T_U64; end
          ISQRT_U32:               a_type_o = T_U32;
          ISQRT_U64:               a_type_o = T_U64;
          default: ;
        endcase
      end

      FAMILY_DATA: begin
        case (sig_o)
          COPY16:    a_type_o = T_RAW16;
          COPY32:    a_type_o = T_RAW32;
          COPY64:    a_type_o = T_RAW64;
          PERMUTE16: begin a_type_o = T_RAW16; b_type_o = T_U32; end
          PERMUTE32: begin a_type_o = T_RAW32; b_type_o = T_U32; end
          PERMUTE64: begin a_type_o = T_RAW64; b_type_o = T_U32; end
          default: ;
        endcase
      end

      default: ;
    endcase
  end

  always_comb begin
    illegal_o = 1'b0;
    legal_sig = 1'b0;
    uses_b = (b_type_o != T_NONE);
    uses_c = (c_type_o != T_NONE);

    case (family_o)

      FAMILY_CONTROL: begin
        case (sig_o)
          // A is a U32 scalar or constant; D, B, C unused.
          SETVL: illegal_o = (d_code_o != 0) || (b_code_o != 0) || (c_code_o != 0) ||
                           (a_code_o < 5'd8) || (a_code_o > K_ONES) || (a_code_o == K_NEG_ZERO);

          // D = A AND B over predicates; D must be P1..P7.
          PAND:  illegal_o = (d_code_o == 0) || (d_code_o > 4'd7) ||
                           (a_code_o > 5'd7) || (b_code_o > 5'd7) || (c_code_o != 0);

          // D = NOT A over predicates; D must be P1..P7.
          PNOT:  illegal_o = (d_code_o == 0) || (d_code_o > 4'd7) ||
                           (a_code_o > 5'd7) || (b_code_o != 0) || (c_code_o != 0);

          default: illegal_o = 1'b1;
        endcase

        // CONTROL commands require PM = 0.
        illegal_o = illegal_o || (pm_o != 0);
      end

      FAMILY_ALU: begin
        // Signatures sheet: which TYPEs each FN supports.
        case (fn)
          // ADD SUB EQ LT SELECT: all six types
          4'd0, 4'd1, 4'd2, 4'd3, 4'd4: legal_sig = (alu_type <= 3'd5);
          // AND XOR SHL SHR CLZ: integer types
          4'd5, 4'd6, 4'd7, 4'd8, 4'd9: legal_sig = (alu_type >= 3'd2) && (alu_type <= 3'd5);
          // ADD_SAT SUB_SAT RSHIFT_RNE: I32 and I64
          4'd10, 4'd11, 4'd12:          legal_sig = (alu_type == 3'd2) || (alu_type == 3'd4);
          default:                      legal_sig = 1'b0;
        endcase

        illegal_o = !legal_sig ||
                  !operand_ok(a_code_o, a_type_o) ||
                  (clz_op ? (b_code_o != 0) : !operand_ok(b_code_o, b_type_o)) ||
                  (select_op ? (c_code_o > 5'd7) : (c_code_o != 0)) ||
                  // Comparisons write P1..P7; P0 is read-only.
                  (predicate_dest_o && ((d_code_o == 0) || (d_code_o > 4'd7))) ||
                  // A scalar result needs scalar or constant inputs.
                  (scalar_dest_o && ((a_code_o < 5'd8) || (!clz_op && (b_code_o < 5'd8))));
      end

      FAMILY_PRODUCT: begin
        illegal_o = (sig_o > MUL_CHECK_U64) ||
                  !operand_ok(a_code_o, a_type_o) ||
                  !operand_ok(b_code_o, b_type_o) ||
                  (uses_c ? !operand_ok(c_code_o, c_type_o) : (c_code_o != 0)) ||
                  (scalar_dest_o && ((a_code_o < 5'd8) || (b_code_o < 5'd8) ||
                                   (uses_c && (c_code_o < 5'd8))));
      end

      FAMILY_REDUCE: begin
        // The result is always a scalar; B and C are unused.
        illegal_o = (sig_o > 7'd17) ||
                  !d_scalar ||
                  !operand_ok(a_code_o, a_type_o) ||
                  (b_code_o != 0) || (c_code_o != 0);
      end

      FAMILY_CAST: begin
        case (sig_o)
          7'd0, 7'd1, 7'd6, 7'd7, 7'd8, 7'd9, 7'd14, 7'd15,
          7'd22, 7'd30, 7'd38, 7'd46,
          7'd48, 7'd49, 7'd50, 7'd51, 7'd52, 7'd53, 7'd54, 7'd55,
          7'd56, 7'd57, 7'd62, 7'd63: legal_sig = 1'b1;
          default:                    legal_sig = 1'b0;
        endcase

        illegal_o = !legal_sig ||
                  !operand_ok(a_code_o, a_type_o) ||
                  !operand_ok(b_code_o, b_type_o) ||
                  (c_code_o != 0) ||
                  (scalar_dest_o && ((a_code_o < 5'd8) || (b_code_o < 5'd8)));
      end

      FAMILY_SPECIAL: begin
        illegal_o = (sig_o > RSQRT_F32) ||
                  !operand_ok(a_code_o, a_type_o) ||
                  (uses_b ? !operand_ok(b_code_o, b_type_o) : (b_code_o != 0)) ||
                  (scalar_dest_o && ((a_code_o < 5'd8) || (uses_b && (b_code_o < 5'd8))));

        if (second_dest_o) begin
          // DIVMOD: C is the remainder register; distinct from D, and both
          // vector or both scalar.
          illegal_o = illegal_o || (c_code_o > 5'd15) ||
                    (c_code_o[3:0] == d_code_o) || (c_code_o[3] != d_code_o[3]);
        end else begin
          illegal_o = illegal_o || (c_code_o != 0);
        end
      end

      FAMILY_DATA: begin
        case (sig_o)
          COPY16, COPY32, COPY64:
            illegal_o = !operand_ok(a_code_o, a_type_o) || (b_code_o != 0) || (c_code_o != 0) ||
                      (scalar_dest_o && (a_code_o < 5'd8));

          // PERMUTE reads and writes vector registers; B is a U32 lane index.
          PERMUTE16, PERMUTE32, PERMUTE64:
            illegal_o = (d_code_o > 4'd7) || (a_code_o > 5'd7) ||
                      !operand_ok(b_code_o, b_type_o) || (c_code_o != 0);

          // IOTA writes a vector register and has no inputs.
          IOTA_U32:
            illegal_o = (d_code_o > 4'd7) || (a_code_o != 0) || (b_code_o != 0) || (c_code_o != 0);

          default: illegal_o = 1'b1;
        endcase
      end

      default: illegal_o = 1'b1;   // FAMILY 111 is invalid

    endcase
  end

endmodule
