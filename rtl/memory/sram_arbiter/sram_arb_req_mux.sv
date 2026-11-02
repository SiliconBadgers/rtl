// Block 2: copy the winner's request onto unified_req and assign its tag
// Matrix and Memory Manager addresses are forced to the row; Vector addresses are forced to the
// granted lane's 128 B slice, and Vector write data is placed in that slice of the row
module sram_arb_req_mux
  import sram_arbiter_pkg::*;
(
  input  logic                                      grant_mm_i,
  input  logic                                      grant_matrix_i,
  input  logic [NUM_LANES-1:0]                      grant_vec_i,
  input  req_tag_e                                  grant_idx_i,

  input  logic                                      matrix_req_is_write_i,
  input  logic [SIZE_WIDTH-1:0]                     matrix_req_size_bytes_i,
  input  logic [ADDR_WIDTH-1:0]                     matrix_req_addr_i,
  input  logic [DATA_WIDTH-1:0]                     matrix_req_wdata_i,

  input  logic [NUM_LANES-1:0]                      vec_req_is_write_i,
  input  logic                                      vec_req_transpose_i,
  input  logic [NUM_LANES-1:0][ADDR_WIDTH-1:0]      vec_req_addr_i,
  input  logic [NUM_LANES-1:0][LANE_DATA_WIDTH-1:0] vec_req_wdata_i,

  input  logic                                      mm_req_is_write_i,
  input  logic [ADDR_WIDTH-1:0]                     mm_req_addr_i,
  input  logic [DATA_WIDTH-1:0]                     mm_req_wdata_i,

  output mem_req_t                                  unified_req_o
);

  logic                      unused_row_offset;
  logic [LANE_IDX_BITS-1:0]  vec_lane;   // granted Vector lane
  logic [ADDR_WIDTH-1:0]     vec_addr;
  logic [DATA_WIDTH-1:0]     vec_wdata;  // lane data placed in its slice of the row
  logic                      vec_is_write;

  always_comb begin
    vec_lane     = '0;
    vec_addr     = '0;
    vec_wdata    = '0;
    vec_is_write = 1'b0;
    for (int unsigned lane = 0; lane < NUM_LANES; lane++) begin
      if (grant_vec_i[lane]) begin
        vec_lane     = LANE_IDX_BITS'(lane);
        vec_addr     = vec_req_addr_i[lane];
        vec_is_write = vec_req_is_write_i[lane];
        vec_wdata[lane*LANE_DATA_WIDTH +: LANE_DATA_WIDTH] = vec_req_wdata_i[lane];
      end
    end
  end

  always_comb begin
    unified_req_o     = '0;
    unified_req_o.tag = grant_idx_i;

    if (grant_mm_i) begin
      unified_req_o.addr       = {mm_req_addr_i[ADDR_WIDTH-1:ROW_OFFSET_BITS],
                                  ROW_OFFSET_BITS'(0)};
      unified_req_o.wdata      = mm_req_wdata_i;
      unified_req_o.is_write   = mm_req_is_write_i;
      unified_req_o.size_bytes = SIZE_WIDTH'(ROW_BYTES);
    end else if (grant_matrix_i) begin
      unified_req_o.addr       = {matrix_req_addr_i[ADDR_WIDTH-1:ROW_OFFSET_BITS],
                                  ROW_OFFSET_BITS'(0)};
      unified_req_o.wdata      = matrix_req_wdata_i;
      unified_req_o.is_write   = matrix_req_is_write_i;
      unified_req_o.size_bytes = matrix_req_size_bytes_i;
    end else if (grant_vec_i != '0) begin
      unified_req_o.addr       = {vec_addr[ADDR_WIDTH-1:ROW_OFFSET_BITS], vec_lane,
                                  LANE_OFFSET_BITS'(0)};
      unified_req_o.wdata      = vec_wdata;
      unified_req_o.is_write   = vec_is_write;
      unified_req_o.size_bytes = SIZE_WIDTH'(LANE_BYTES);
      unified_req_o.transpose  = vec_req_transpose_i;
    end
  end

  // Byte offsets within the row are replaced by the aligned row or lane slice (illegal input)
  assign unused_row_offset = ^{matrix_req_addr_i[ROW_OFFSET_BITS-1:0],
                               mm_req_addr_i[ROW_OFFSET_BITS-1:0],
                               vec_addr[ROW_OFFSET_BITS-1:0]};

endmodule