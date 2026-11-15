// Self-checking testbench for sram_arbiter.
//
// Drives all six sources with ready/valid traffic against sram_model, keeps a reference memory,
// and checks read data, priority, byte enables, tags, ordering, scoreboard completions,
// bank-busy spacing, reset and the Memory Manager burst contract.
//
// Scheduling: inputs are driven 1 ns after the rising clock edge; outputs are sampled at the
// falling edge, when the combinational paths have settled.
//
// TestInvalid = 0 runs the normal tests. TestInvalid = 1 runs only the invalid-input test and
// needs the DUT built with SRAM_ARB_NO_INPUT_ASSERTS defined (run_sim.sh does this).
module sram_arbiter_tb
  import sram_arbiter_pkg::*;
#(
  parameter int unsigned BankBusyCycles = 0,
  parameter int unsigned SramLatency    = 3,
  parameter int unsigned RandomCycles   = 20000,
  parameter bit          TestInvalid    = 1'b0
);
  timeunit 1ns; timeprecision 1ps;

  // Sources are indexed by their tag value: TagMm, TagMatrix, then one per Vector lane.
  localparam int unsigned SRC_MM = int'(TagMm);
  localparam int unsigned SRC_MATRIX = int'(TagMatrix);
  localparam int unsigned VEC_SRC_BASE = int'(TagVec0);
  localparam int unsigned NUM_SOURCES = VEC_SRC_BASE + NUM_LANES;
  localparam int unsigned NUM_ROWS = 8;  // rows stored by sram_model
  localparam int unsigned ROW_IDX_BITS = $clog2(NUM_ROWS);
  localparam int unsigned EXP_DEPTH = 256;  // expected-read ring buffer depth
  localparam int unsigned EXP_IDX_BITS = $clog2(EXP_DEPTH);
  localparam int unsigned MAX_ERRORS = 20;
  localparam int unsigned TIMEOUT_CYCLES = RandomCycles + 10000;

  // ---------------------------------------------------------------------------------------------
  // DUT and model signals
  // ---------------------------------------------------------------------------------------------
  logic clk;
  logic rst_n;

  logic matrix_req_valid;
  logic matrix_req_ready;
  logic matrix_req_is_write;
  logic [SIZE_WIDTH-1:0] matrix_req_size_bytes;
  logic [ADDR_WIDTH-1:0] matrix_req_addr;
  logic [DATA_WIDTH-1:0] matrix_req_wdata;
  logic matrix_rsp_valid;
  logic [DATA_WIDTH-1:0] matrix_rsp_rdata;
  logic [NUM_LANES-1:0] vec_req_valid;
  logic [NUM_LANES-1:0] vec_req_ready;
  logic [NUM_LANES-1:0] vec_req_is_write;
  logic vec_req_transpose;
  logic [NUM_LANES-1:0][ADDR_WIDTH-1:0] vec_req_addr;
  logic [NUM_LANES-1:0][LANE_DATA_WIDTH-1:0] vec_req_wdata;
  logic [NUM_LANES-1:0] vec_rsp_valid;
  logic [NUM_LANES-1:0][LANE_DATA_WIDTH-1:0] vec_rsp_rdata;
  logic mm_req_valid;
  logic mm_req_ready;
  logic mm_req_is_write;
  logic [ADDR_WIDTH-1:0] mm_req_addr;
  logic [DATA_WIDTH-1:0] mm_req_wdata;
  logic mm_rsp_valid;
  logic [DATA_WIDTH-1:0] mm_rsp_rdata;
  logic sram_rd_req;
  logic sram_wr_req;
  logic sram_req_ready;
  logic [ADDR_WIDTH-1:0] sram_addr;
  logic [DATA_WIDTH-1:0] sram_wdata;
  logic [WR_BE_WIDTH-1:0] sram_wr_be;
  req_tag_e sram_tag;
  logic sram_transpose;
  logic sram_rsp_valid;
  req_tag_e sram_rsp_tag;
  logic sram_rsp_is_write;
  logic [DATA_WIDTH-1:0] sram_rdata;
  logic sb_rd_done;
  req_tag_e sb_rd_tag;
  logic sb_wr_done;
  req_tag_e sb_wr_tag;

  // Model outputs, and an override used to inject an illegal response tag.
  logic model_rsp_valid;
  req_tag_e model_rsp_tag;
  logic model_rsp_is_write;
  logic [DATA_WIDTH-1:0] model_rdata;
  logic inject_rsp;
  logic [TAG_WIDTH-1:0] inject_tag;

  // ---------------------------------------------------------------------------------------------
  // Testbench state
  // ---------------------------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] ref_mem[NUM_ROWS];
  logic [DATA_WIDTH-1:0] exp_rd_buf[NUM_SOURCES][EXP_DEPTH];  // expected read data
  logic exp_rd_check[NUM_SOURCES][EXP_DEPTH];  // 0: data not checked
  logic [EXP_IDX_BITS-1:0] exp_head[NUM_SOURCES];
  int unsigned exp_count[NUM_SOURCES];
  int unsigned pend_rd[NUM_SOURCES];  // reads awaiting sb_rd_done
  int unsigned pend_wr[NUM_SOURCES];  // writes awaiting sb_wr_done
  int unsigned n_accepted[NUM_SOURCES];
  int unsigned n_rd_rsp[NUM_SOURCES];
  int unsigned n_wr_cpl[NUM_SOURCES];
  longint last_issue[NUM_LANES];  // cycle each bank group was last used
  longint cycle;
  int unsigned errors;
  int unsigned n_conflict_stalls;
  int unsigned n_transpose;
  int unsigned n_unchecked;

  // Per-source request registers (index = tag value). Vector data uses the low 1024 bits.
  logic req_valid[NUM_SOURCES];
  logic req_is_write[NUM_SOURCES];
  logic [ADDR_WIDTH-1:0] req_addr[NUM_SOURCES];
  logic [DATA_WIDTH-1:0] req_wdata[NUM_SOURCES];
  logic [SIZE_WIDTH-1:0] req_size[NUM_SOURCES];
  logic accepted[NUM_SOURCES];

  int unsigned valid_pct;  // chance an idle source starts a request
  int unsigned ready_pct;  // chance sram_req_ready is 1
  bit transpose_mode;  // Vector reads only, with transpose set
  bit invalid_mode;  // generate illegal addresses and sizes

  // ---------------------------------------------------------------------------------------------
  // DUT and SRAM model
  // ---------------------------------------------------------------------------------------------
  sram_arbiter #(
    .BankBusyCycles(BankBusyCycles)
  ) u_dut (
    .clk_i                  (clk),
    .rst_ni                 (rst_n),
    .matrix_req_valid_i     (matrix_req_valid),
    .matrix_req_ready_o     (matrix_req_ready),
    .matrix_req_is_write_i  (matrix_req_is_write),
    .matrix_req_size_bytes_i(matrix_req_size_bytes),
    .matrix_req_addr_i      (matrix_req_addr),
    .matrix_req_wdata_i     (matrix_req_wdata),
    .matrix_rsp_valid_o     (matrix_rsp_valid),
    .matrix_rsp_rdata_o     (matrix_rsp_rdata),
    .vec_req_valid_i        (vec_req_valid),
    .vec_req_ready_o        (vec_req_ready),
    .vec_req_is_write_i     (vec_req_is_write),
    .vec_req_transpose_i    (vec_req_transpose),
    .vec_req_addr_i         (vec_req_addr),
    .vec_req_wdata_i        (vec_req_wdata),
    .vec_rsp_valid_o        (vec_rsp_valid),
    .vec_rsp_rdata_o        (vec_rsp_rdata),
    .mm_req_valid_i         (mm_req_valid),
    .mm_req_ready_o         (mm_req_ready),
    .mm_req_is_write_i      (mm_req_is_write),
    .mm_req_addr_i          (mm_req_addr),
    .mm_req_wdata_i         (mm_req_wdata),
    .mm_rsp_valid_o         (mm_rsp_valid),
    .mm_rsp_rdata_o         (mm_rsp_rdata),
    .sram_rd_req_o          (sram_rd_req),
    .sram_wr_req_o          (sram_wr_req),