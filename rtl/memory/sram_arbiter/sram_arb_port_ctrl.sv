// Block 5: final decision, engine ready, SRAM request and byte enables
// Combinational paths(not sure, correct me if im wrong) *_valid_i -> *_req_ready_o and sram_req_ready_i -> *_req_ready_o
module sram_arb_port_ctrl
  import sram_arbiter_pkg::*;
(
  input  logic                   grant_valid_i,
  input  logic                   grant_mm_i,
  input  logic                   grant_matrix_i,
  input  logic [NUM_LANES-1:0]   grant_vec_i,
  input  mem_req_t               unified_req_i,
  input  logic [NUM_LANES-1:0]   lane_mask_i,
  input  logic                   read_path_en_i,
  input  logic                   write_path_en_i,
  input  logic                   conflict_i,
  input  logic                   sram_req_ready_i,

  output logic                   can_proceed_o,
  output logic                   matrix_req_ready_o,
  output logic [NUM_LANES-1:0]   vec_req_ready_o,
  output logic                   mm_req_ready_o,

  output logic                   sram_rd_req_o,
  output logic                   sram_wr_req_o,
  output logic [ADDR_WIDTH-1:0]  sram_addr_o,
  output logic [DATA_WIDTH-1:0]  sram_wdata_o,
  output logic [WR_BE_WIDTH-1:0] sram_wr_be_o,
  output req_tag_e               sram_tag_o,
  output logic                   sram_transpose_o
);

  logic [WR_BE_WIDTH-1:0] wr_be;
  logic [WR_BE_WIDTH-1:0] vec_be;   // lane slices from lane_mask
  logic [WR_BE_WIDTH-1:0] size_be;  // (byte 0 to size_bytes-1)
  logic                   unused_is_write;

  assign can_proceed_o = grant_valid_i & ~conflict_i & sram_req_ready_i;

  assign mm_req_ready_o     = can_proceed_o & grant_mm_i;
  assign matrix_req_ready_o = can_proceed_o & grant_matrix_i;
  assign vec_req_ready_o    = can_proceed_o ? grant_vec_i : '0;

  assign sram_rd_req_o = can_proceed_o & read_path_en_i;
  assign sram_wr_req_o = can_proceed_o & write_path_en_i;

  // Byte enables: Vector writes enable their lane slices; Matrix and Memory Manager writes enable
  //bytes 0 to size_bytes-1 of the row (size_bytes is 512 for the Memory Manager)

  always_comb begin
    vec_be = '0;
    for (int unsigned lane = 0; lane < NUM_LANES; lane++) begin
      vec_be[lane*LANE_BYTES +: LANE_BYTES] = {LANE_BYTES{lane_mask_i[lane]}};
    end
  end

  always_comb begin
    size_be = '0;
    for (int unsigned b = 0; b < ROW_BYTES; b++) begin
      size_be[b] = (b < 32'(unified_req_i.size_bytes));
    end
  end

  assign wr_be = (grant_vec_i != '0) ? vec_be : size_be;

  assign sram_wr_be_o     = sram_wr_req_o ? wr_be : '0;
  assign sram_addr_o      = unified_req_i.addr;
  assign sram_wdata_o     = unified_req_i.wdata;
  assign sram_tag_o       = unified_req_i.tag;
  assign sram_transpose_o = unified_req_i.transpose;

  // Direction comes from read_path_en_i/write_path_en_i
  assign unused_is_write = unified_req_i.is_write;

endmodule
