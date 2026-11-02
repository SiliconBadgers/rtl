// Block 3: split the addr into bank and row and build the lane mask
module sram_arb_addr_decode
  import sram_arbiter_pkg::*;
(
  input  mem_req_t                 unified_req_i,
  input  logic                     grant_mm_i,
  input  logic                     grant_matrix_i,
  input  logic [NUM_LANES-1:0]     grant_vec_i,
  output logic [BANK_ID_BITS-1:0]  bank_id_o,      //first bank touched
  output logic [BANK_ROW_BITS-1:0] bank_offset_o,  //row within every bank
  output logic [NUM_LANES-1:0]     lane_mask_o,    //active 128 B slices
  output logic                     read_path_en_o,
  output logic                     write_path_en_o
);

  logic unused_addr;

  assign bank_id_o     = unified_req_i.addr[BANK_WORD_BITS +: BANK_ID_BITS];
  assign bank_offset_o = unified_req_i.addr[ROW_OFFSET_BITS +: BANK_ROW_BITS];

  assign lane_mask_o = (grant_mm_i | grant_matrix_i) ? {NUM_LANES{1'b1}} : grant_vec_i;

  assign read_path_en_o  = ~unified_req_i.is_write;
  assign write_path_en_o =  unified_req_i.is_write;

  //Address bits below the bank word are not used 
  assign unused_addr = ^{unified_req_i.addr[ADDR_WIDTH-1:SRAM_ADDR_BITS],
                         unified_req_i.addr[BANK_WORD_BITS-1:0],
                         unified_req_i.wdata, unified_req_i.size_bytes,
                         unified_req_i.transpose, unified_req_i.tag};

endmodule
