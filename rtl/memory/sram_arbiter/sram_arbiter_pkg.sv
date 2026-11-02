// Shared constants and types for sram_arbiter
package sram_arbiter_pkg;

  localparam int unsigned NUM_LANES       = 4;
  localparam int unsigned ADDR_WIDTH      = 32;
  localparam int unsigned DATA_WIDTH      = 4096;  // 512 B SRAM row
  localparam int unsigned LANE_DATA_WIDTH = 1024;  // 128 B per Vector lane
  localparam int unsigned TAG_WIDTH       = 4;
  localparam int unsigned SIZE_WIDTH      = 10;    // to index 1-512 bytes
  localparam int unsigned ROW_BYTES       = DATA_WIDTH / 8;       // 512
  localparam int unsigned LANE_BYTES      = LANE_DATA_WIDTH / 8;  // 128
  localparam int unsigned WR_BE_WIDTH     = ROW_BYTES;            // one enable per byte

  // Address fields.
  localparam int unsigned ROW_OFFSET_BITS  = $clog2(ROW_BYTES);   // 9: byte within row
  localparam int unsigned LANE_OFFSET_BITS = $clog2(LANE_BYTES);  // 7: byte within lane slice
  localparam int unsigned LANE_IDX_BITS    = $clog2(NUM_LANES);   // 2
  localparam int unsigned NUM_BANKS        = 32;
  localparam int unsigned BANK_ID_BITS     = $clog2(NUM_BANKS);   // 5
  localparam int unsigned BANK_WORD_BYTES  = ROW_BYTES / NUM_BANKS;               // 16
  localparam int unsigned BANK_WORD_BITS   = $clog2(BANK_WORD_BYTES);             // 4
  localparam int unsigned SRAM_BYTES       = 8 * 1024 * 1024;                     // 8 MaddB
  localparam int unsigned SRAM_ADDR_BITS   = $clog2(SRAM_BYTES);                  // 23
  localparam int unsigned BANK_ROW_BITS    = SRAM_ADDR_BITS - ROW_OFFSET_BITS;    // 14

  //encoding
  typedef enum logic [TAG_WIDTH-1:0] {
    TagMm     = 4'd0,
    TagMatrix = 4'd1,
    TagVec0   = 4'd2,
    TagVec1   = 4'd3,
    TagVec2   = 4'd4,
    TagVec3   = 4'd5
  } req_tag_e;

  // One 512 B row access. A Memory Manager burst is a sequence of these,
  // one per handshake; the arbiter keeps no burst state.
  typedef struct packed {
    logic [ADDR_WIDTH-1:0] addr;        // byte address, row aligned after Block 2
    logic [DATA_WIDTH-1:0] wdata;       // Vector data placed in its lane slice
    logic                  is_write;
    logic [SIZE_WIDTH-1:0] size_bytes;  // 512 for MM, 128 for Vector, 1-512 for Matrix
    logic                  transpose;
    req_tag_e              tag;
  } mem_req_t;

  // Tag of Vector lane
  function automatic req_tag_e vec_lane_tag(logic [LANE_IDX_BITS-1:0] lane);
    case (lane)
      2'd0:    vec_lane_tag = TagVec0;
      2'd1:    vec_lane_tag = TagVec1;
      2'd2:    vec_lane_tag = TagVec2;
      default: vec_lane_tag = TagVec3;
    endcase
  endfunction

endpackage
