// Shift-register delay line used by bpu_sa_array for the A, tile-flag and B skews
// and the capture timing.
//
// A value presented on d_i in cycle t appears on q_o in cycle t + Depth.
// Depth = 0 is a plain wire with no registers.
//
// Clock and reset
//   clk_i   Rising-edge clock. The only clock domain.
//   rst_ni  Active-low reset. Assertion may be asynchronous; deassertion must be
//           synchronous to clk_i and meet the registers' recovery and removal
//           timing. The instantiating design owns that guarantee (in this block,
//           bpu_sa_array passes its own reset through; see its header).
//           With Reset = 1 every stage clears to 0 while rst_ni is low.
//           With Reset = 0 the stages are data storage, are not reset, and
//           rst_ni is unused.
//
// Parameters
//   Width  Bits per stage, >= 1.
//   Depth  Number of register stages, in clock cycles, >= 0.
//   Reset  1 for control bits that must not hold garbage after reset (valid and
//          tile-switch flags); 0 for data.
module bpu_sa_delay #(
  parameter int unsigned Width = 1,
  parameter int unsigned Depth = 1,
  parameter bit          Reset = 1'b0
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic [Width-1:0] d_i,
  output logic [Width-1:0] q_o
);

`ifndef SYNTHESIS
  initial begin
    if (Width < 1) begin
      $fatal(1, "bpu_sa_delay: Width must be at least 1");
    end
  end
`endif

  if (Depth == 0) begin : g_wire
    logic unused_clk_rst;

    assign unused_clk_rst = clk_i ^ rst_ni;
    assign q_o            = d_i;
  end else begin : g_regs
    // data_q[j] holds the input presented j + 1 cycles ago.
    logic [Depth-1:0][Width-1:0] data_q;

    if (Reset) begin : g_rst
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          data_q <= '0;
        end else begin
          data_q[0] <= d_i;
          for (int j = 1; j < Depth; j++) begin
            data_q[j] <= data_q[j-1];
          end
        end
      end
    end else begin : g_norst
      logic unused_rst;

      assign unused_rst = rst_ni;

      always_ff @(posedge clk_i) begin
        data_q[0] <= d_i;
        for (int j = 1; j < Depth; j++) begin
          data_q[j] <= data_q[j-1];
        end
      end
    end

    assign q_o = data_q[Depth-1];
  end

endmodule
