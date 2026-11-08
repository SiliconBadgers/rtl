// One SRAM read stream of bpu_sa_sram_wrapper: walks one operand (A, B, or a
// scale table) one SRAM row at a time and buffers the rows that come back.
//
// start_i loads the operand's base address and length in bytes. The stream then
// wants a read (want_o) while bytes remain and fewer than BufRows rows are
// reserved. A row is reserved when the wrapper loads this stream's read into its
// request register (grant_i), and released when the consumer pops it (pop_i), so
// a response always has a buffer entry waiting: the arbiter's responses cannot be
// stalled. req_addr_o / req_size_o give the next read: one whole row
// (DataW/8 bytes), or exactly the bytes that remain for the last one.
// Responses for this stream (push_i, data_i) arrive in request order; head_o is
// the oldest buffered row while empty_o is 0.
//
// Clock and reset
//   clk_i   Rising-edge clock. The only clock domain.
//   rst_ni  Active-low reset. Assertion may be asynchronous; deassertion must be
//           synchronous to clk_i and meet recovery and removal timing. The
//           instantiating design owns that guarantee. Reset clears the address,
//           byte count, reservations and buffer pointers; the buffered rows are
//           data storage and are not reset.
//
// Parameters
//   AddrW, DataW, SizeW  the sram_arbiter port widths (DataW = one SRAM row)
//   BytesW               width of the byte count, enough for the longest operand
//   BufRows              rows buffered (and reads in flight) at most, >= 1
module bpu_sa_read_stream #(
  parameter int unsigned AddrW   = 32,
  parameter int unsigned DataW   = 4096,
  parameter int unsigned SizeW   = 10,
  parameter int unsigned BytesW  = 25,
  parameter int unsigned BufRows = 2
) (
  input logic clk_i,
  input logic rst_ni,

  // Command
  input logic              start_i,
  input logic [ AddrW-1:0] addr_i,
  input logic [BytesW-1:0] bytes_i,

  // Requests
  output logic                             want_o,
  output logic [$clog2(BufRows + 1) - 1:0] credit_o,    // rows reserved now
  input  logic                             grant_i,
  output logic [                AddrW-1:0] req_addr_o,
  output logic [                SizeW-1:0] req_size_o,

  // Responses and the consumer
  input  logic             push_i,
  input  logic [DataW-1:0] data_i,
  input  logic             pop_i,
  output logic [DataW-1:0] head_o,
  output logic             empty_o
);

  localparam int unsigned ROW_BYTES = DataW / 8;
  localparam int unsigned CREDIT_WIDTH = $clog2(BufRows + 1);

  logic [       AddrW-1:0] addr_q;
  logic [      BytesW-1:0] left_q;
  logic [CREDIT_WIDTH-1:0] credit_q;
  logic [      BytesW-1:0] size;
  logic                    full;
  logic                    unused_full;

`ifndef SYNTHESIS
  // The wrapper grants only a stream that wants, and starts a stream only when it
  // has nothing reserved. All three are 0 during reset.
  always @(posedge clk_i) begin
    GrantWanted_A :
    assert (!(grant_i === 1'b1 && want_o !== 1'b1))
    else $error("bpu_sa_read_stream: grant without a pending want");
    StartIdle_A :
    assert (!(start_i === 1'b1 && credit_q != '0))
    else $error("bpu_sa_read_stream: start with rows still reserved");
  end
`endif

  assign size       = (left_q > BytesW'(ROW_BYTES)) ? BytesW'(ROW_BYTES) : left_q;
  assign want_o     = (left_q != '0) && (credit_q < CREDIT_WIDTH'(BufRows));
  assign credit_o   = credit_q;
  assign req_addr_o = addr_q;
  assign req_size_o = SizeW'(size);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      addr_q   <= '0;
      left_q   <= '0;
      credit_q <= '0;
    end else begin
      if (start_i) begin
        addr_q <= addr_i;
        left_q <= bytes_i;
      end else if (grant_i) begin
        addr_q <= addr_q + AddrW'(ROW_BYTES);
        left_q <= left_q - size;
      end
      if (grant_i && !pop_i) begin
        credit_q <= credit_q + 1'b1;
      end else if (pop_i && !grant_i) begin
        credit_q <= credit_q - 1'b1;
      end
    end
  end

  bpu_sa_fifo #(
    .Width(DataW),
    .Depth(BufRows)
  ) u_buf (
    .clk_i,
    .rst_ni,
    .push_i,
    .data_i,
    .pop_i,
    .data_o(head_o),
    .empty_o,
    .full_o(full)
  );

  // Reservations cover the buffer, so full only matters to the FIFO's own checks.
  assign unused_full = full;

endmodule
