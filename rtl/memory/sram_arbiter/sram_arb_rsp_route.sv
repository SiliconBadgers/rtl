// Block 6: route SRAM responses by tag and report completions to the scoreboard
// Read responses pulse the owning engine's *_rsp_valid_o; writes only pulse sb_wr_done_o

module sram_arb_rsp_route
  import sram_arbiter_pkg::*;
(
  input  logic                                      sram_rsp_valid_i,
  input  req_tag_e                                  sram_rsp_tag_i,
  input  logic                                      sram_rsp_is_write_i,
  input  logic [DATA_WIDTH-1:0]                     sram_rdata_i,

  output logic                                      matrix_rsp_valid_o,
  output logic [DATA_WIDTH-1:0]                     matrix_rsp_rdata_o,
  output logic [NUM_LANES-1:0]                      vec_rsp_valid_o,
  output logic [NUM_LANES-1:0][LANE_DATA_WIDTH-1:0] vec_rsp_rdata_o,
  output logic                                      mm_rsp_valid_o,
  output logic [DATA_WIDTH-1:0]                     mm_rsp_rdata_o,

  output logic                                      sb_rd_done_o,
  output req_tag_e                                  sb_rd_tag_o,
  output logic                                      sb_wr_done_o,
  output req_tag_e                                  sb_wr_tag_o
);

  logic tag_legal;
  logic rd_rsp;

  assign tag_legal = (sram_rsp_tag_i <= TagVec3);
  assign rd_rsp    = sram_rsp_valid_i & tag_legal & ~sram_rsp_is_write_i;

  assign mm_rsp_valid_o     = rd_rsp & (sram_rsp_tag_i == TagMm);
  assign matrix_rsp_valid_o = rd_rsp & (sram_rsp_tag_i == TagMatrix);

  always_comb begin
    for (int unsigned lane = 0; lane < NUM_LANES; lane++) begin
      vec_rsp_valid_o[lane] = rd_rsp & (sram_rsp_tag_i == vec_lane_tag(LANE_IDX_BITS'(lane)));
      vec_rsp_rdata_o[lane] = sram_rdata_i[lane*LANE_DATA_WIDTH +: LANE_DATA_WIDTH];
    end
  end

  assign mm_rsp_rdata_o     = sram_rdata_i;
  assign matrix_rsp_rdata_o = sram_rdata_i;

  assign sb_rd_done_o = rd_rsp;
  assign sb_rd_tag_o  = sram_rsp_tag_i;
  assign sb_wr_done_o = sram_rsp_valid_i & tag_legal & sram_rsp_is_write_i;
  assign sb_wr_tag_o  = sram_rsp_tag_i;

endmodule
