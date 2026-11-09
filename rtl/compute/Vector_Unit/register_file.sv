// Central register file: V0-V7 (one DataWidth element per lane), S0-S7, P0-P7
// (one bit per lane, P0 always true) and VL.
//
// Reads are combinational. Writes happen on the clock edge, so a command can read
// and write the same register (all inputs are read before any output is written).
// There is no forwarding: the unit is single-cycle, and forwarding a result back
// into the operands that produce it would form a combinational loop.
//
// Constants (operand codes 16-19) depend on the operand type, so the lanes make
// them; these read ports return 0 for those codes.
module register_file #(
  parameter int DataWidth = 64,
  parameter int NumLanes  = 8
) (
  input  logic                               clk_i,
  input  logic                               rst_ni,

  input  logic [4:0]                         raddr_a_i,   // operand code of A: 0-7 V, 8-15 S
  input  logic [4:0]                         raddr_b_i,   // operand code of B
  input  logic [4:0]                         raddr_c_i,   // operand code of C
  input  logic [2:0]                         pm_sel_i,    // execution mask predicate P0..P7

  output logic [NumLanes-1:0][DataWidth-1:0] rdata_a_o,   // V: per lane, S: broadcast
  output logic [NumLanes-1:0][DataWidth-1:0] rdata_b_o,
  output logic [NumLanes-1:0][DataWidth-1:0] rdata_c_o,
  output logic [NumLanes-1:0]                rdata_pm_o,  // P[pm_sel]
  output logic [NumLanes-1:0]                rdata_p_a_o, // P[A] (PAND, PNOT)
  output logic [NumLanes-1:0]                rdata_p_b_o, // P[B] (PAND)
  output logic [NumLanes-1:0]                rdata_p_c_o, // P[C] (SELECT)
  output logic [31:0]                        vl_o,

  // Lane mask shared by both write ports (V and P writes only).
  input  logic [NumLanes-1:0]                lane_mask_i,

  // Write port D
  input  logic [3:0]                         waddr_d_i,
  input  logic                               wren_v_d_i,
  input  logic                               wren_s_d_i,
  input  logic                               wren_p_d_i,
  input  logic [1:0]                         wsize_d_i,   // 0: 16 bits, 1: 32 bits, else 64
  input  logic [NumLanes-1:0][DataWidth-1:0] wdata_d_i,   // S writes take lane 0
  input  logic [NumLanes-1:0]                wdata_p_d_i,

  // Write port C (DIVMOD remainder)
  input  logic [3:0]                         waddr_c_i,
  input  logic                               wren_v_c_i,
  input  logic                               wren_s_c_i,
  input  logic                               wren_p_c_i,
  input  logic [1:0]                         wsize_c_i,
  input  logic [NumLanes-1:0][DataWidth-1:0] wdata_c_i,
  input  logic [NumLanes-1:0]                wdata_p_c_i,

  // VL is stored as given; the top level faults a value above NumLanes.
  input  logic                               setvl_en_i,
  input  logic [31:0]                        setvl_val_i
);

  logic [NumLanes-1:0][DataWidth-1:0] v_reg [0:7];
  logic [DataWidth-1:0]                s_reg [0:7];
  logic [NumLanes-1:0]                 p_reg [0:7];
  logic [31:0]                          vl_reg;

  function automatic [DataWidth-1:0] format_wdata(
    input logic [DataWidth-1:0] data,
    input logic [1:0]            size
  );
    case (size)
      2'b00:   format_wdata = {{(DataWidth-16){1'b0}}, data[15:0]};
      2'b01:   format_wdata = {{(DataWidth-32){1'b0}}, data[31:0]};
      default: format_wdata = data;
    endcase
  endfunction

  // Codes 0-7 read a V register, 8-15 broadcast an S register, anything else is 0.
  function automatic logic [NumLanes-1:0][DataWidth-1:0] read_operand(input logic [4:0] addr);
    if (addr <= 5'd7) begin
      read_operand = v_reg[addr[2:0]];
    end else if (addr <= 5'd15) begin
      for (int i = 0; i < NumLanes; i++) begin
        read_operand[i] = s_reg[addr[2:0]];
      end
    end else begin
      read_operand = '0;
    end
  endfunction

  // P0 always reads as true; codes above 7 read as 0.
  function automatic logic [NumLanes-1:0] read_predicate(input logic [4:0] addr);
    if (addr > 5'd7) begin
      read_predicate = '0;
    end else if (addr[2:0] == 3'd0) begin
      read_predicate = '1;
    end else begin
      read_predicate = p_reg[addr[2:0]];
    end
  endfunction

  always_comb begin
    rdata_a_o   = read_operand(raddr_a_i);
    rdata_b_o   = read_operand(raddr_b_i);
    rdata_c_o   = read_operand(raddr_c_i);
    rdata_pm_o  = read_predicate({2'b00, pm_sel_i});
    rdata_p_a_o = read_predicate(raddr_a_i);
    rdata_p_b_o = read_predicate(raddr_b_i);
    rdata_p_c_o = read_predicate(raddr_c_i);
  end

  assign vl_o = vl_reg;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int r = 0; r < 8; r++) begin
        v_reg[r] <= '0;
        s_reg[r] <= '0;
        p_reg[r] <= '0;
      end
      p_reg[0] <= '1;
      vl_reg   <= '0;
    end else begin
      p_reg[0] <= '1;

      if (wren_v_d_i) begin
        for (int lane = 0; lane < NumLanes; lane++) begin
          if (lane_mask_i[lane]) begin
            v_reg[waddr_d_i[2:0]][lane] <= format_wdata(wdata_d_i[lane], wsize_d_i);
          end
        end
      end

      if (wren_s_d_i) begin
        s_reg[waddr_d_i[2:0]] <= format_wdata(wdata_d_i[0], wsize_d_i);
      end

      if (wren_p_d_i && (waddr_d_i[2:0] != 3'd0)) begin
        for (int lane = 0; lane < NumLanes; lane++) begin
          if (lane_mask_i[lane]) begin
            p_reg[waddr_d_i[2:0]][lane] <= wdata_p_d_i[lane];
          end
        end
      end

      // The decoder guarantees C != D when both ports write.
      if (wren_v_c_i) begin
        for (int lane = 0; lane < NumLanes; lane++) begin
          if (lane_mask_i[lane]) begin
            v_reg[waddr_c_i[2:0]][lane] <= format_wdata(wdata_c_i[lane], wsize_c_i);
          end
        end
      end

      if (wren_s_c_i) begin
        s_reg[waddr_c_i[2:0]] <= format_wdata(wdata_c_i[0], wsize_c_i);
      end

      if (wren_p_c_i && (waddr_c_i[2:0] != 3'd0)) begin
        for (int lane = 0; lane < NumLanes; lane++) begin
          if (lane_mask_i[lane]) begin
            p_reg[waddr_c_i[2:0]][lane] <= wdata_p_c_i[lane];
          end
        end
      end

      if (setvl_en_i) begin
        vl_reg <= setvl_val_i;
      end
    end
  end

endmodule
