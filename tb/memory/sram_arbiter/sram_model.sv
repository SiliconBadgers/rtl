// Behavioural SRAM for sram_arbiter_tb: in order, fixed latency, byte-enable writes.
// Simulation only, not synthesizable.
// Limitations:
// - Transpose is not modelled. A request with transpose_i = 1 is not performed: a transposed
//   write leaves memory unchanged and a transposed read returns all zeros. Each one is reported
//   with $warning (first occurrence), and the testbench does not check data for them.
// - Only NumRows rows are stored; higher row addresses alias onto them.
// - Contents are cleared by rst_ni.
module sram_model
  import sram_arbiter_pkg::*;
#(
  parameter int unsigned Latency = 3,  // cycles from request to response, >= 1
  parameter int unsigned NumRows = 8   // rows stored, power of two
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,
  input  logic                       rd_req_i,
  input  logic                       wr_req_i,
  input  logic     [ ADDR_WIDTH-1:0] addr_i,
  input  logic     [ DATA_WIDTH-1:0] wdata_i,
  input  logic     [WR_BE_WIDTH-1:0] wr_be_i,
  input  req_tag_e                   tag_i,
  input  logic                       transpose_i,
  output logic                       rsp_valid_o,
  output req_tag_e                   rsp_tag_o,
  output logic                       rsp_is_write_o,
  output logic     [ DATA_WIDTH-1:0] rdata_o
);

  localparam int unsigned ROW_IDX_BITS = (NumRows > 1) ? $clog2(NumRows) : 1;

  // Pipeline stage 0 is the newest; stage Latency-1 drives the response.
  logic [     NumRows-1:0][DATA_WIDTH-1:0] mem_q;
  logic [     NumRows-1:0][DATA_WIDTH-1:0] mem_d;
  logic [     Latency-1:0]                 pipe_valid_q;
  logic [     Latency-1:0]                 pipe_valid_d;
  logic [     Latency-1:0][ TAG_WIDTH-1:0] pipe_tag_q;
  logic [     Latency-1:0][ TAG_WIDTH-1:0] pipe_tag_d;
  logic [     Latency-1:0]                 pipe_is_write_q;
  logic [     Latency-1:0]                 pipe_is_write_d;
  logic [     Latency-1:0][DATA_WIDTH-1:0] pipe_rdata_q;
  logic [     Latency-1:0][DATA_WIDTH-1:0] pipe_rdata_d;
  logic [ROW_IDX_BITS-1:0]                 row;
  logic                                    unused_addr;
  logic                                    transpose_seen_q;  // report only the first one

  if (Latency < 1) begin : gen_latency_check
    $error("sram_model: Latency must be at least 1");
  end

  if ((NumRows & (NumRows - 1)) != 0) begin : gen_num_rows_check
    $error("sram_model: NumRows must be a power of two");
  end

  assign row = addr_i[ROW_OFFSET_BITS+:ROW_IDX_BITS];

  // Higher row bits alias onto the stored rows; the byte offset is covered by wr_be_i.
  assign unused_addr = ^{addr_i[ADDR_WIDTH-1:ROW_OFFSET_BITS+ROW_IDX_BITS],
                         addr_i[ROW_OFFSET_BITS-1:0]};

  always_comb begin
    mem_d = mem_q;
    if (wr_req_i && !transpose_i) begin
      for (int unsigned b = 0; b < WR_BE_WIDTH; b++) begin
        if (wr_be_i[b]) begin
          mem_d[row][8*b+:8] = wdata_i[8*b+:8];
        end
      end
    end
  end

  always_comb begin
    pipe_valid_d       = pipe_valid_q << 1;
    pipe_tag_d         = pipe_tag_q << TAG_WIDTH;
    pipe_is_write_d    = pipe_is_write_q << 1;
    pipe_rdata_d       = pipe_rdata_q << DATA_WIDTH;
    pipe_valid_d[0]    = rd_req_i | wr_req_i;
    pipe_tag_d[0]      = tag_i;
    pipe_is_write_d[0] = wr_req_i;
    pipe_rdata_d[0]    = (rd_req_i && !transpose_i) ? mem_q[row] : '0;
  end

  // Waiver: WIDTHCONCAT, because clearing the 32 Kbit model memory with '0 is intended; applies to
  // this reset assignment only.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      /* verilator lint_off WIDTHCONCAT */
      mem_q           <= '0;
      /* verilator lint_on WIDTHCONCAT */
      pipe_valid_q    <= '0;
      pipe_tag_q      <= '0;
      pipe_is_write_q <= '0;
    end else begin
      mem_q           <= mem_d;
      pipe_valid_q    <= pipe_valid_d;
      pipe_tag_q      <= pipe_tag_d;
      pipe_is_write_q <= pipe_is_write_d;
    end
  end

  // Read data is qualified by pipe_valid_q, so it needs no reset.
  always_ff @(posedge clk_i) begin
    pipe_rdata_q <= pipe_rdata_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      transpose_seen_q <= 1'b0;
    end else if ((rd_req_i || wr_req_i) && transpose_i && !transpose_seen_q) begin
      $warning("sram_model: transpose not modelled; transposed requests are not performed");
      transpose_seen_q <= 1'b1;
    end
  end

  assign rsp_valid_o    = pipe_valid_q[Latency-1];
  assign rsp_tag_o      = req_tag_e'(pipe_tag_q[Latency-1]);
  assign rsp_is_write_o = pipe_is_write_q[Latency-1];
  assign rdata_o        = pipe_rdata_q[Latency-1];

endmodule
