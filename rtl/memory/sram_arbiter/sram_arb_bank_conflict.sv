// Block 4: bank conflict check
// Each 128 B lane slice of the row maps to its own group of banks. After an access, every group
// it touched stays busy for BankBusyCycles cycles. a request whose lane_mask overlaps a busy
// group is held. BankBusyCycles = 0 models banks that accept one access every cycle
module sram_arb_bank_conflict
  import sram_arbiter_pkg::*;
#(
  parameter int unsigned BankBusyCycles = 0
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic [NUM_LANES-1:0] lane_mask_i,
  input  logic                 issue_i,       // request sent to the SRAM this cycle
  output logic                 conflict_o
);

  localparam int unsigned CntWidth = (BankBusyCycles > 0) ? $clog2(BankBusyCycles + 1) : 1;

  logic [NUM_LANES-1:0][CntWidth-1:0] stall_cycles_d;
  logic [NUM_LANES-1:0][CntWidth-1:0] stall_cycles_q;
  logic [NUM_LANES-1:0]               group_busy;

  //kept in its own block: computing it inside the next-state block would create a false combinational loop through conflict_o -> can_proceed -> issue_i
  always_comb begin
    for (int unsigned g = 0; g < NUM_LANES; g++) begin
      group_busy[g] = (stall_cycles_q[g] != '0);
    end
  end

  always_comb begin
    for (int unsigned g = 0; g < NUM_LANES; g++) begin
      stall_cycles_d[g] = stall_cycles_q[g];
      if (issue_i && lane_mask_i[g]) begin
        stall_cycles_d[g] = CntWidth'(BankBusyCycles);
      end else if (group_busy[g]) begin
        stall_cycles_d[g] = stall_cycles_q[g] - 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stall_cycles_q <= '0;
    end else begin
      stall_cycles_q <= stall_cycles_d;
    end
  end

  assign conflict_o = |(lane_mask_i & group_busy);

endmodule
