// SIMD unit top: command decoder, register_file (V, S, P, VL), N lanes, and the
// cross-lane units (REDUCE, PERMUTE routing).
//
// Handshake: the issuer presents command with valid and holds both until done or
// error is high (sampled at a clock edge).
// - Most commands take one cycle: they are checked and committed on the next edge.
// - DIV, RCP, DIVMOD, DIV_RNE and RSQRT use sequential units. The first cycle starts
//   them and raises busy; done (or error) comes in the cycle they finish:
//   32/64 cycles for 32/64-bit integer division, 50 for FP DIV/RCP, 28 for RSQRT.
//   An illegal command reports error immediately without starting.
// Any fault writes nothing and blocks the sequence until reset.
module vec_simd #(
  parameter int NumLanes = 8
) (
  input logic clk_i,
  input logic rst_ni,
  input logic valid_i,  // command presented this cycle
  input logic [31:0] command_i,
  input logic strict_i,  // set once per compute sequence
  output logic done_o,  // command committed this cycle
  output logic error_o,  // command faulted (or sequence already faulted)
  output logic faulted_o,  // sticky: sequence invalid until reset
  output logic busy_o,  // a multi-cycle command is running
  // Saturations recorded this cycle, per stage (also counted in strict mode).
  output logic [$clog2(NumLanes+1)-1:0] saturated_add_count_o,
  output logic [$clog2(NumLanes+1)-1:0] saturated_sub_count_o,
  output logic [$clog2(NumLanes+1)-1:0] saturated_product_count_o,
  output logic [$clog2(NumLanes+1)-1:0] saturated_convert_count_o
);

  localparam int COUNT_WIDTH = $clog2(NumLanes + 1);

  localparam logic [6:0] SETVL = 7'd0;
  localparam logic [6:0] PAND = 7'd1;
  localparam logic [6:0] PNOT = 7'd2;

  localparam logic [6:0] PERMUTE16 = 7'd3;
  localparam logic [6:0] PERMUTE64 = 7'd5;

  localparam logic [4:0] K_ZERO = 5'd16;
  localparam logic [4:0] K_ONE = 5'd18;
  localparam logic [4:0] K_ONES = 5'd19;

  logic [2:0] family;
  logic [6:0] sig;
  logic [3:0] d_code;
  logic [4:0] a_code, b_code, c_code;
  logic [3:0] a_type, b_type, c_type;
  logic [2:0] pm;
  logic is_control, is_alu, is_product, is_reduce, is_cast, is_special, is_data;
  logic predicate_dest, scalar_dest, second_dest, multi_cycle, illegal;
  logic        running;  // multi-cycle units are working
  logic        unit_start;  // starts the lanes' sequential units
  logic        exec_ready;  // results of this command are available
  logic        lane_command;  // executed by the lanes
  logic        is_permute;

  logic [31:0] vl;

  // register_file read ports
  logic [NumLanes-1:0][63:0] rf_a, rf_b, rf_c;
  logic [NumLanes-1:0] rf_pm, rf_p_a, rf_p_b, rf_p_c;

  // Register writes for this command. Everything that changes architectural state
  // goes through these signals into register_file (a writeback buffer can sit here).
  logic [NumLanes-1:0] wr_lane_mask;
  logic wr_v_d, wr_s_d, wr_p_d;
  logic [NumLanes-1:0][63:0] wr_data_d;
  logic [NumLanes-1:0]       wr_data_p_d;
  logic wr_v_c, wr_s_c;
  logic [NumLanes-1:0][63:0] wr_data_c;
  logic                      wr_setvl;

  logic [NumLanes-1:0]       below_vl;
  logic [NumLanes-1:0] lane_enable, lane_error, lane_finished;
  logic [NumLanes-1:0] lane_saturated_add, lane_saturated_sub;
  logic [NumLanes-1:0] lane_saturated_product, lane_saturated_convert;
  logic [NumLanes-1:0] lane_predicate_result;
  logic [        63:0] lane_result           [NumLanes];
  logic [        63:0] lane_result2          [NumLanes];
  logic [        63:0] lane_a_value          [NumLanes];
  logic [        63:0] lane_b_value          [NumLanes];
  logic [        63:0] permute_data          [NumLanes];
  logic [NumLanes-1:0] permute_index_bad;

  logic                any_enabled;
  logic [63:0] scalar_result, scalar_result2;
  logic [31:0] setvl_value;
  logic setvl_error, permute_error;
  logic        reduce_error;
  logic [63:0] reduce_result;
  logic fault, commit;

  vec_decoder u_vec_decoder (
    .command_i(command_i),
    .family_o(family),
    .sig_o(sig),
    .d_code_o(d_code),
    .a_code_o(a_code),
    .b_code_o(b_code),
    .c_code_o(c_code),
    .pm_o(pm),
    .a_type_o(a_type),
    .b_type_o(b_type),
    .c_type_o(c_type),
    .is_control_o(is_control),
    .is_alu_o(is_alu),
    .is_product_o(is_product),
    .is_reduce_o(is_reduce),
    .is_cast_o(is_cast),
    .is_special_o(is_special),
    .is_data_o(is_data),
    .predicate_dest_o(predicate_dest),
    .scalar_dest_o(scalar_dest),
    .second_dest_o(second_dest),
    .multi_cycle_o(multi_cycle),
    .illegal_o(illegal)
  );

  assign is_permute = is_data && (sig >= PERMUTE16) && (sig <= PERMUTE64);

  register_file #(
    .DataWidth(64),
    .NumLanes (NumLanes)
  ) u_register_file (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .raddr_a_i  (a_code),
    .raddr_b_i  (b_code),
    .raddr_c_i  (c_code),
    .pm_sel_i   (pm),
    .rdata_a_o  (rf_a),
    .rdata_b_o  (rf_b),
    .rdata_c_o  (rf_c),
    .rdata_pm_o (rf_pm),
    .rdata_p_a_o(rf_p_a),
    .rdata_p_b_o(rf_p_b),
    .rdata_p_c_o(rf_p_c),
    .vl_o       (vl),
    .lane_mask_i(wr_lane_mask),
    .waddr_d_i  (d_code),
    .wren_v_d_i (wr_v_d),
    .wren_s_d_i (wr_s_d),
    .wren_p_d_i (wr_p_d),
    .wsize_d_i  (2'b11),         // results are already zero-filled
    .wdata_d_i  (wr_data_d),
    .wdata_p_d_i(wr_data_p_d),
    .waddr_c_i  (c_code[3:0]),
    .wren_v_c_i (wr_v_c),
    .wren_s_c_i (wr_s_c),
    .wren_p_c_i (1'b0),
    .wsize_c_i  (2'b11),
    .wdata_c_i  (wr_data_c),
    .wdata_p_c_i('0),
    .setvl_en_i (wr_setvl),
    .setvl_val_i(setvl_value)
  );

  genvar i;
  generate
    for (i = 0; i < NumLanes; i++) begin : g_lanes
      assign below_vl[i] = (i < vl);

      // PERMUTE: this lane reads A from the lane its B selects. Every lane's A is
      // read before any write, so in-place permutation works.
      assign permute_index_bad[i] = (lane_b_value[i][31:0] >= NumLanes[31:0]);
      assign permute_data[i] = permute_index_bad[i] ? 64'b0 : lane_a_value[lane_b_value[i][31:0]];

      vec_lane #(
        .LaneIndex(i)
      ) u_vec_lane (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .family_i(family),
        .sig_i(sig),
        .a_code_i(a_code),
        .b_code_i(b_code),
        .c_code_i(c_code),
        .a_type_i(a_type),
        .b_type_i(b_type),
        .c_type_i(c_type),
        .vl_i(vl),
        .strict_i(strict_i),
        .start_i(unit_start),
        .a_reg_i(rf_a[i]),
        .b_reg_i(rf_b[i]),
        .c_reg_i(rf_c[i]),
        .pm_bit_i(rf_pm[i]),
        .select_bit_i(rf_p_c[i]),
        .permute_data_i(permute_data[i]),
        .enable_o(lane_enable[i]),
        .finished_o(lane_finished[i]),
        .error_o(lane_error[i]),
        .saturated_add_o(lane_saturated_add[i]),
        .saturated_sub_o(lane_saturated_sub[i]),
        .saturated_product_o(lane_saturated_product[i]),
        .saturated_convert_o(lane_saturated_convert[i]),
        .predicate_result_o(lane_predicate_result[i]),
        .a_value_o(lane_a_value[i]),
        .b_value_o(lane_b_value[i]),
        .result_o(lane_result[i]),
        .result2_o(lane_result2[i])
      );
    end
  endgenerate

  // REDUCE across lanes into one scalar.
  vec_reduce #(
    .NumLanes(NumLanes)
  ) u_vec_reduce (
    .lane_value_i(lane_a_value),
    .lane_enable_i(lane_enable),
    .vl_i(vl),
    .sig_i(sig),
    .error_o(reduce_error),
    .result_o(reduce_result)
  );

  // Scalar D executes once: every enabled lane sees the same scalar inputs, so take
  // the lowest enabled lane. This also gives scalar SELECT its lowest-lane C bit.
  always_comb begin
    any_enabled = |lane_enable;
    scalar_result = 64'b0;
    scalar_result2 = 64'b0;
    for (int k = NumLanes - 1; k >= 0; k--) begin
      if (lane_enable[k]) begin
        scalar_result  = lane_result[k];
        scalar_result2 = lane_result2[k];
      end
    end
  end

  // SETVL reads a U32 scalar or constant and must not exceed the lane count.
  always_comb begin
    case (a_code)
      K_ZERO:  setvl_value = 32'd0;
      K_ONE:   setvl_value = 32'd1;
      K_ONES:  setvl_value = 32'hFFFF_FFFF;
      default: setvl_value = rf_a[0][31:0];  // S register, broadcast
    endcase
    setvl_error = is_control && (sig == SETVL) && (setvl_value > NumLanes[31:0]);
  end

  // An enabled lane's index must be below the physical lane count; the source
  // lane itself may be disabled.
  assign permute_error = is_permute && |(permute_index_bad & lane_enable);

  assign lane_command  = is_alu || is_product || is_cast || is_special || is_data;

  // Multi-cycle commands: start the units in the first cycle, then wait. All lanes
  // run the same operation, so they finish together.
  assign unit_start    = valid_i && !faulted_o && !illegal && multi_cycle && !running;
  assign exec_ready    = !multi_cycle || (running && (&lane_finished));
  assign busy_o        = running;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      running <= 1'b0;
    end else if (unit_start) begin
      running <= 1'b1;
    end else if (running && (&lane_finished)) begin
      running <= 1'b0;
    end
  end

  // Check every enabled lane before committing any output.
  assign fault  = valid_i && !faulted_o &&
                  (illegal ||
                   (exec_ready && (setvl_error || permute_error ||
                                   (lane_command && |lane_error) ||
                                   (is_reduce && reduce_error))));
  assign commit = valid_i && !faulted_o && !fault && exec_ready;
  assign done_o = commit;
  assign error_o = valid_i && (faulted_o || fault);

  // Saturation is recorded in strict mode too. Scalar D counts once.
  always_comb begin
    saturated_add_count_o = '0;
    saturated_sub_count_o = '0;
    saturated_product_count_o = '0;
    saturated_convert_count_o = '0;
    if (valid_i && !faulted_o && !illegal && exec_ready && lane_command) begin
      if (scalar_dest) begin
        saturated_add_count_o     = COUNT_WIDTH'(|lane_saturated_add);
        saturated_sub_count_o     = COUNT_WIDTH'(|lane_saturated_sub);
        saturated_product_count_o = COUNT_WIDTH'(|lane_saturated_product);
        saturated_convert_count_o = COUNT_WIDTH'(|lane_saturated_convert);
      end else begin
        for (int k = 0; k < NumLanes; k++) begin
          saturated_add_count_o = saturated_add_count_o + COUNT_WIDTH'(lane_saturated_add[k]);
          saturated_sub_count_o = saturated_sub_count_o + COUNT_WIDTH'(lane_saturated_sub[k]);
          saturated_product_count_o = saturated_product_count_o +
                                      COUNT_WIDTH'(lane_saturated_product[k]);
          saturated_convert_count_o = saturated_convert_count_o +
                                      COUNT_WIDTH'(lane_saturated_convert[k]);
        end
      end
    end
  end

  // Register writes, all gated by commit. Inputs were read combinationally, so a
  // command may write a register it reads.
  always_comb begin
    wr_lane_mask = '0;
    wr_v_d = 1'b0;
    wr_s_d = 1'b0;
    wr_p_d = 1'b0;
    wr_data_d = '0;
    wr_data_p_d = '0;
    wr_v_c = 1'b0;
    wr_s_c = 1'b0;
    wr_data_c = '0;
    wr_setvl = 1'b0;

    if (commit && is_control) begin
      case (sig)
        SETVL:   wr_setvl = 1'b1;
        // Update lanes below VL; higher bits keep their values.
        PAND: begin
          wr_p_d       = 1'b1;
          wr_lane_mask = below_vl;
          wr_data_p_d  = rf_p_a & rf_p_b;
        end
        PNOT: begin
          wr_p_d       = 1'b1;
          wr_lane_mask = below_vl;
          wr_data_p_d  = ~rf_p_a;
        end
        default: ;
      endcase
    end

    // REDUCE always writes its scalar, zero when no lane is enabled.
    if (commit && is_reduce) begin
      wr_s_d       = 1'b1;
      wr_data_d[0] = reduce_result;
    end

    if (commit && lane_command) begin
      if (predicate_dest) begin
        // EQ / LT: enabled lanes write their bit; disabled lanes keep theirs.
        wr_p_d       = 1'b1;
        wr_lane_mask = lane_enable;
        wr_data_p_d  = lane_predicate_result;
      end else if (scalar_dest) begin
        // Scalar D executes once (lowest enabled lane); no enabled lane, no write.
        wr_s_d       = any_enabled;
        wr_data_d[0] = scalar_result;
        // Scalar DIVMOD remainder; C != D is guaranteed by the decoder.
        wr_s_c       = any_enabled && second_dest;
        wr_data_c[0] = scalar_result2;
      end else begin
        // Vector D: enabled lanes only. DIVMOD's C is a V register when D is.
        wr_v_d       = 1'b1;
        wr_v_c       = second_dest;
        wr_lane_mask = lane_enable;
        for (int k = 0; k < NumLanes; k++) begin
          wr_data_d[k] = lane_result[k];
          wr_data_c[k] = lane_result2[k];
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      faulted_o <= 1'b0;
    end else if (fault) begin
      faulted_o <= 1'b1;
    end
  end

endmodule
