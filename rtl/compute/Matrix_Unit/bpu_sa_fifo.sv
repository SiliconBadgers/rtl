// First-in first-out buffer used by bpu_sa_sram_wrapper for the A and B row
// buffers and the read-order queue.
//
// push_i writes data_i at the tail; pop_i removes the head. data_o shows the head
// while empty_o is 0. A push and a pop may happen in the same cycle. The caller
// never pushes while full_o is 1 and never pops while empty_o is 1
// (NoOverflow_A, NoUnderflow_A); bpu_sa_sram_wrapper guarantees this with credits.
//
// Clock and reset
//   clk_i   Rising-edge clock. The only clock domain.
//   rst_ni  Active-low reset. Assertion may be asynchronous; deassertion must be
//           synchronous to clk_i and meet recovery and removal timing. The
//           instantiating design owns that guarantee. Reset empties the FIFO
//           (pointers and count); the entries are data storage and are not reset.
//
// Parameters
//   Width  Bits per entry, >= 1.
//   Depth  Entries, >= 1.
module bpu_sa_fifo #(
  parameter int unsigned Width = 1,
  parameter int unsigned Depth = 2
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             push_i,
  input  logic [Width-1:0] data_i,
  input  logic             pop_i,
  output logic [Width-1:0] data_o,
  output logic             empty_o,
  output logic             full_o
);

  localparam int unsigned PTR_WIDTH = $clog2((Depth > 1) ? Depth : 2);
  localparam int unsigned COUNT_WIDTH = $clog2(Depth + 1);

  logic [      Width-1:0] mem_q    [Depth];
  logic [  PTR_WIDTH-1:0] rd_ptr_q;
  logic [  PTR_WIDTH-1:0] wr_ptr_q;
  logic [COUNT_WIDTH-1:0] count_q;

`ifndef SYNTHESIS
  initial begin
    if (Width < 1 || Depth < 1) begin
      $fatal(1, "bpu_sa_fifo: Width and Depth must be at least 1");
    end
  end

  // Both are held at 0 during reset.
  always @(posedge clk_i) begin
    NoOverflow_A :
    assert (!(push_i === 1'b1 && full_o === 1'b1))
    else $error("bpu_sa_fifo: push while full");
    NoUnderflow_A :
    assert (!(pop_i === 1'b1 && empty_o === 1'b1))
    else $error("bpu_sa_fifo: pop while empty");
  end
`endif

  assign data_o  = mem_q[rd_ptr_q];
  assign empty_o = (count_q == '0);
  assign full_o  = (count_q == COUNT_WIDTH'(Depth));

  always_ff @(posedge clk_i) begin
    if (push_i) begin
      mem_q[wr_ptr_q] <= data_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_ptr_q <= '0;
      wr_ptr_q <= '0;
      count_q  <= '0;
    end else begin
      if (push_i) begin
        if (wr_ptr_q == PTR_WIDTH'(Depth - 1)) begin
          wr_ptr_q <= '0;
        end else begin
          wr_ptr_q <= wr_ptr_q + 1'b1;
        end
      end
      if (pop_i) begin
        if (rd_ptr_q == PTR_WIDTH'(Depth - 1)) begin
          rd_ptr_q <= '0;
        end else begin
          rd_ptr_q <= rd_ptr_q + 1'b1;
        end
      end
      if (push_i && !pop_i) begin
        count_q <= count_q + 1'b1;
      end else if (pop_i && !push_i) begin
        count_q <= count_q - 1'b1;
      end
    end
  end

endmodule
