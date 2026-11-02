// sram_arbiter: shares the 8 MB SRAM between the Matrix engine, four Vector lanes and the
// Memory Manager

// Request channels are ready/valid; response and scoreboard channels are one-cycle signals. 
// One request is sent to the SRAM per cycle, in acceptance order.
// Reset: the only state is the Block 4 busy counters, cleared by rst_ni. 
module sram_arbiter
  import sram_arbiter_pkg::*;
#(
  parameter int unsigned BankBusyCycles = 0  // check sram_arb_bank_conflict
) (
  input  logic                                      clk_i,
  input  logic                                      rst_ni,

  // Matrix engine
  input  logic                                      matrix_req_valid_i,
  output logic                                      matrix_req_ready_o,
  input  logic                                      matrix_req_is_write_i,
  input  logic [SIZE_WIDTH-1:0]                     matrix_req_size_bytes_i,
  input  logic [ADDR_WIDTH-1:0]                     matrix_req_addr_i,
  input  logic [DATA_WIDTH-1:0]                     matrix_req_wdata_i,
  output logic                                      matrix_rsp_valid_o,
  output logic [DATA_WIDTH-1:0]                     matrix_rsp_rdata_o,

  // Vector engine, one channel per lane
  input  logic [NUM_LANES-1:0]                      vec_req_valid_i,
  output logic [NUM_LANES-1:0]                      vec_req_ready_o,
  input  logic [NUM_LANES-1:0]                      vec_req_is_write_i,
  input  logic                                      vec_req_transpose_i,
  input  logic [NUM_LANES-1:0][ADDR_WIDTH-1:0]      vec_req_addr_i,
  input  logic [NUM_LANES-1:0][LANE_DATA_WIDTH-1:0] vec_req_wdata_i,
  output logic [NUM_LANES-1:0]                      vec_rsp_valid_o,
  output logic [NUM_LANES-1:0][LANE_DATA_WIDTH-1:0] vec_rsp_rdata_o,

  // Memory Manager
  input  logic                                      mm_req_valid_i,
  output logic                                      mm_req_ready_o,
  input  logic                                      mm_req_is_write_i,
  input  logic [ADDR_WIDTH-1:0]                     mm_req_addr_i,
  input  logic [DATA_WIDTH-1:0]                     mm_req_wdata_i,
  output logic                                      mm_rsp_valid_o,
  output logic [DATA_WIDTH-1:0]                     mm_rsp_rdata_o,

  // SRAM request
  output logic                                      sram_rd_req_o,
  output logic                                      sram_wr_req_o,
  input  logic                                      sram_req_ready_i,
  output logic [ADDR_WIDTH-1:0]                     sram_addr_o,
  output logic [DATA_WIDTH-1:0]                     sram_wdata_o,
  output logic [WR_BE_WIDTH-1:0]                    sram_wr_be_o,
  output req_tag_e                                  sram_tag_o,
  output logic                                      sram_transpose_o,

  // SRAM response
  input  logic                                      sram_rsp_valid_i,
  input  req_tag_e                                  sram_rsp_tag_i,
  input  logic                                      sram_rsp_is_write_i,
  input  logic [DATA_WIDTH-1:0]                     sram_rdata_i,

  // Scoreboard completions
  output logic                                      sb_rd_done_o,
  output req_tag_e                                  sb_rd_tag_o,
  output logic                                      sb_wr_done_o,
  output req_tag_e                                  sb_wr_tag_o
);

  logic                     grant_valid;
  logic                     grant_mm;
  logic                     grant_matrix;
  logic [NUM_LANES-1:0]     grant_vec;
  req_tag_e                 grant_idx;
  mem_req_t                 unified_req;
  logic [BANK_ID_BITS-1:0]  bank_id;
  logic [BANK_ROW_BITS-1:0] bank_offset;
  logic [NUM_LANES-1:0]     lane_mask;
  logic                     read_path_en;
  logic                     write_path_en;
  logic                     conflict;
  logic                     can_proceed;
  logic                     unused_decode;

  // vec_lane_tag() and the tag encoding assume four Vector lanes for now
  if (NUM_LANES != 4) begin : gen_num_lanes_check
    $error("sram_arbiter supports NUM_LANES = 4 only");
  end

  // Block 1
  sram_arb_priority u_priority_arb (
    .mm_valid_i     (mm_req_valid_i),
    .matrix_valid_i (matrix_req_valid_i),
    .vec_valid_i    (vec_req_valid_i),
    .grant_valid_o  (grant_valid),
    .grant_mm_o     (grant_mm),
    .grant_matrix_o (grant_matrix),
    .grant_vec_o    (grant_vec),
    .grant_idx_o    (grant_idx)
  );

  // Block 2
  sram_arb_req_mux u_req_mux (
    .grant_mm_i              (grant_mm),
    .grant_matrix_i          (grant_matrix),
    .grant_vec_i             (grant_vec),
    .grant_idx_i             (grant_idx),
    .matrix_req_is_write_i,
    .matrix_req_size_bytes_i,
    .matrix_req_addr_i,
    .matrix_req_wdata_i,
    .vec_req_is_write_i,
    .vec_req_transpose_i,
    .vec_req_addr_i,
    .vec_req_wdata_i,
    .mm_req_is_write_i,
    .mm_req_addr_i,
    .mm_req_wdata_i,
    .unified_req_o           (unified_req)
  );

  // Block 3
  sram_arb_addr_decode u_addr_decode (
    .unified_req_i   (unified_req),
    .grant_mm_i      (grant_mm),
    .grant_matrix_i  (grant_matrix),
    .grant_vec_i     (grant_vec),
    .bank_id_o       (bank_id),
    .bank_offset_o   (bank_offset),
    .lane_mask_o     (lane_mask),
    .read_path_en_o  (read_path_en),
    .write_path_en_o (write_path_en)
  );

  // Block 4
  sram_arb_bank_conflict #(
    .BankBusyCycles (BankBusyCycles)
  ) u_bank_conflict (
    .clk_i,
    .rst_ni,
    .lane_mask_i (lane_mask),
    .issue_i     (can_proceed),
    .conflict_o  (conflict)
  );

  // Block 5
  sram_arb_port_ctrl u_port_ctrl (
    .grant_valid_i      (grant_valid),
    .grant_mm_i         (grant_mm),
    .grant_matrix_i     (grant_matrix),
    .grant_vec_i        (grant_vec),
    .unified_req_i      (unified_req),
    .lane_mask_i        (lane_mask),
    .read_path_en_i     (read_path_en),
    .write_path_en_i    (write_path_en),
    .conflict_i         (conflict),
    .sram_req_ready_i,
    .can_proceed_o      (can_proceed),
    .matrix_req_ready_o,
    .vec_req_ready_o,
    .mm_req_ready_o,
    .sram_rd_req_o,
    .sram_wr_req_o,
    .sram_addr_o,
    .sram_wdata_o,
    .sram_wr_be_o,
    .sram_tag_o,
    .sram_transpose_o
  );

  // Block 6
  sram_arb_rsp_route u_rsp_route (
    .sram_rsp_valid_i,
    .sram_rsp_tag_i,
    .sram_rsp_is_write_i,
    .sram_rdata_i,
    .matrix_rsp_valid_o,
    .matrix_rsp_rdata_o,
    .vec_rsp_valid_o,
    .vec_rsp_rdata_o,
    .mm_rsp_valid_o,
    .mm_rsp_rdata_o,
    .sb_rd_done_o,
    .sb_rd_tag_o,
    .sb_wr_done_o,
    .sb_wr_tag_o
  );

  // bank_id and bank_offset are decoded for the SRAM wrapper and for debug
  // the SRAM takes the full row address on sram_addr_o
  assign unused_decode = ^{bank_id, bank_offset};


endmodule