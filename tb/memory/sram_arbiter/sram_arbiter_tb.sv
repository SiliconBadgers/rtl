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
    .sram_req_ready_i       (sram_req_ready),
    .sram_addr_o            (sram_addr),
    .sram_wdata_o           (sram_wdata),
    .sram_wr_be_o           (sram_wr_be),
    .sram_tag_o             (sram_tag),
    .sram_transpose_o       (sram_transpose),
    .sram_rsp_valid_i       (sram_rsp_valid),
    .sram_rsp_tag_i         (sram_rsp_tag),
    .sram_rsp_is_write_i    (sram_rsp_is_write),
    .sram_rdata_i           (sram_rdata),
    .sb_rd_done_o           (sb_rd_done),
    .sb_rd_tag_o            (sb_rd_tag),
    .sb_wr_done_o           (sb_wr_done),
    .sb_wr_tag_o            (sb_wr_tag)
  );

  sram_model #(
    .Latency(SramLatency),
    .NumRows(NUM_ROWS)
  ) u_sram (
    .clk_i         (clk),
    .rst_ni        (rst_n),
    .rd_req_i      (sram_rd_req),
    .wr_req_i      (sram_wr_req),
    .addr_i        (sram_addr),
    .wdata_i       (sram_wdata),
    .wr_be_i       (sram_wr_be),
    .tag_i         (sram_tag),
    .transpose_i   (sram_transpose),
    .rsp_valid_o   (model_rsp_valid),
    .rsp_tag_o     (model_rsp_tag),
    .rsp_is_write_o(model_rsp_is_write),
    .rdata_o       (model_rdata)
  );

  assign sram_rsp_valid    = inject_rsp | model_rsp_valid;
  assign sram_rsp_tag      = inject_rsp ? req_tag_e'(inject_tag) : model_rsp_tag;
  assign sram_rsp_is_write = inject_rsp ? 1'b0 : model_rsp_is_write;
  assign sram_rdata        = inject_rsp ? '1 : model_rdata;

  initial begin
    clk = 1'b0;
    forever begin
      #5;
      clk = ~clk;
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------------------------
  function automatic bit src_is_vec(int unsigned src);
    return src >= VEC_SRC_BASE;
  endfunction

  function automatic int unsigned lane_of(int unsigned src);
    return src - VEC_SRC_BASE;
  endfunction

  function automatic logic [DATA_WIDTH-1:0] rand_row();
    logic [DATA_WIDTH-1:0] value;
    for (int unsigned w = 0; w < DATA_WIDTH / 32; w++) begin
      value[32*w+:32] = $urandom;
    end
    return value;
  endfunction

  // Address the DUT must send to the SRAM for the current request of `src`.
  function automatic logic [ADDR_WIDTH-1:0] exp_sram_addr(int unsigned src);
    logic [ADDR_WIDTH-1:0] addr;
    addr = {req_addr[src][ADDR_WIDTH-1:ROW_OFFSET_BITS], ROW_OFFSET_BITS'(0)};
    if (src_is_vec(src)) begin
      addr[ROW_OFFSET_BITS-1:0] = ROW_OFFSET_BITS'(lane_of(src) * LANE_BYTES);
    end
    return addr;
  endfunction

  // Byte enables for a write from `src`, computed independently of the DUT.
  function automatic logic [WR_BE_WIDTH-1:0] exp_be(int unsigned src);
    logic [WR_BE_WIDTH-1:0] be;
    be = '0;
    if (src_is_vec(src)) begin
      be[lane_of(src)*LANE_BYTES+:LANE_BYTES] = '1;
    end else begin
      for (int unsigned b = 0; b < ROW_BYTES; b++) begin
        be[b] = (b < req_size[src]);
      end
    end
    return be;
  endfunction

  // Write data placed in the row as the DUT must place it.
  function automatic logic [DATA_WIDTH-1:0] exp_wdata_row(int unsigned src);
    logic [DATA_WIDTH-1:0] data;
    data = req_wdata[src];
    if (src_is_vec(src)) begin
      data = '0;
      data[lane_of(src)*LANE_DATA_WIDTH+:LANE_DATA_WIDTH] = req_wdata[src][LANE_DATA_WIDTH-1:0];
    end
    return data;
  endfunction

  function automatic logic [NUM_LANES-1:0] groups_of(int unsigned src);
    logic [NUM_LANES-1:0] groups;
    groups = '1;
    if (src_is_vec(src)) begin
      groups = NUM_LANES'(1) << lane_of(src);
    end
    return groups;
  endfunction

  function automatic bit rsp_valid_for(req_tag_e tag);
    bit valid;
    if (tag == TagMm) begin
      valid = mm_rsp_valid;
    end else if (tag == TagMatrix) begin
      valid = matrix_rsp_valid;
    end else begin
      valid = vec_rsp_valid[LANE_IDX_BITS'(tag-TagVec0)];
    end
    return valid;
  endfunction

  task automatic err(string msg);
    errors++;
    $display("[%0t] ERROR cycle %0d: %s", $time, cycle, msg);
    if (errors > MAX_ERRORS) begin
      $display("FAIL: too many errors");
      $finish;
    end
  endtask

  // Pick a row address: mostly random, sometimes the first or last row of the 8 MiB SRAM.
  function automatic logic [ADDR_WIDTH-1:0] pick_row_addr();
    logic        [BANK_ROW_BITS-1:0] row;
    int unsigned                     pick;
    pick = $urandom_range(9);
    unique case (pick)
      0:       row = '0;
      1:       row = '1;
      default: row = BANK_ROW_BITS'($urandom);
    endcase
    return ADDR_WIDTH'(row) << ROW_OFFSET_BITS;
  endfunction

  // Start a new request on an idle source.
  task automatic new_request(int unsigned src);
    logic        [ADDR_WIDTH-1:0] row_addr;
    int unsigned                  pick;
    row_addr          = pick_row_addr();
    req_valid[src]    = 1'b1;
    req_is_write[src] = 1'($urandom_range(1));
    req_wdata[src]    = rand_row();
    req_addr[src]     = row_addr;
    if (src == SRC_MATRIX) begin
      pick = $urandom_range(7);
      unique case (pick)
        0:       req_size[src] = SIZE_WIDTH'(1);
        1:       req_size[src] = SIZE_WIDTH'(ROW_BYTES);
        default: req_size[src] = SIZE_WIDTH'($urandom_range(ROW_BYTES, 1));
      endcase
    end else if (src == SRC_MM) begin
      req_size[src] = SIZE_WIDTH'(ROW_BYTES);
    end else begin
      req_addr[src] = row_addr | (ADDR_WIDTH'(lane_of(src)) << LANE_OFFSET_BITS);
      req_size[src] = SIZE_WIDTH'(LANE_BYTES);
    end
    if (transpose_mode) begin
      req_is_write[src] = 1'b0;
    end
    if (invalid_mode) begin
      // Illegal requests: random byte offset within the row, and Matrix sizes of 0 or > 512.
      req_addr[src][ROW_OFFSET_BITS-1:0] = ROW_OFFSET_BITS'($urandom);
      if (src == SRC_MATRIX) begin
        pick = $urandom_range(2);
        unique case (pick)
          0:       req_size[src] = '0;
          1:       req_size[src] = SIZE_WIDTH'($urandom_range(1023, ROW_BYTES + 1));
          default: req_size[src] = SIZE_WIDTH'($urandom_range(ROW_BYTES, 1));
        endcase
      end
    end
  endtask

  // Copy the per-source registers onto the DUT ports. Whole vectors are assigned at once so the
  // simulator sees one update per port.
  task automatic drive_ports();
    logic [NUM_LANES-1:0]                      lane_valid;
    logic [NUM_LANES-1:0]                      lane_is_write;
    logic [NUM_LANES-1:0][     ADDR_WIDTH-1:0] lane_addr;
    logic [NUM_LANES-1:0][LANE_DATA_WIDTH-1:0] lane_wdata;
    for (int unsigned lane = 0; lane < NUM_LANES; lane++) begin
      lane_valid[lane]    = req_valid[VEC_SRC_BASE+lane];
      lane_is_write[lane] = req_is_write[VEC_SRC_BASE+lane];
      lane_addr[lane]     = req_addr[VEC_SRC_BASE+lane];
      lane_wdata[lane]    = req_wdata[VEC_SRC_BASE+lane][LANE_DATA_WIDTH-1:0];
    end
    mm_req_valid          = req_valid[SRC_MM];
    mm_req_is_write       = req_is_write[SRC_MM];
    mm_req_addr           = req_addr[SRC_MM];
    mm_req_wdata          = req_wdata[SRC_MM];
    matrix_req_valid      = req_valid[SRC_MATRIX];
    matrix_req_is_write   = req_is_write[SRC_MATRIX];
    matrix_req_addr       = req_addr[SRC_MATRIX];
    matrix_req_wdata      = req_wdata[SRC_MATRIX];
    matrix_req_size_bytes = req_size[SRC_MATRIX];
    vec_req_valid         = lane_valid;
    vec_req_is_write      = lane_is_write;
    vec_req_addr          = lane_addr;
    vec_req_wdata         = lane_wdata;
  endtask

  // Forget all outstanding work, as at reset.
  task automatic clear_tracking();
    for (int unsigned row = 0; row < NUM_ROWS; row++) begin
      ref_mem[row] = '0;
    end
    for (int unsigned src = 0; src < NUM_SOURCES; src++) begin
      req_valid[src] = 1'b0;
      accepted[src]  = 1'b0;
      exp_head[src]  = '0;
      exp_count[src] = 0;
      pend_rd[src]   = 0;
      pend_wr[src]   = 0;
    end
    for (int unsigned group = 0; group < NUM_LANES; group++) begin
      last_issue[group] = -1000;
    end
  endtask

  // ---------------------------------------------------------------------------------------------
  // Checks, run once per cycle at the falling edge
  // ---------------------------------------------------------------------------------------------
  task automatic check_handshake_and_issue();
    logic [NUM_SOURCES-1:0] ready_vec;
    logic [  NUM_LANES-1:0] groups;
    int                     winner;
    int                     exp_winner;

    ready_vec = {vec_req_ready, matrix_req_ready, mm_req_ready};

    // At most one ready, only to a valid source, and only to the highest-priority valid source.
    if (!$onehot0(ready_vec)) begin
      err("more than one ready asserted");
    end
    winner = -1;
    for (int src = 0; src < NUM_SOURCES; src++) begin
      accepted[src] = req_valid[src] && ready_vec[src];
      if (ready_vec[src] && !req_valid[src]) begin
        err($sformatf("ready to idle source %0d", src));
      end
      if (accepted[src]) begin
        winner = src;
      end
    end
    exp_winner = -1;
    for (int src = NUM_SOURCES - 1; src >= 0; src--) begin
      if (req_valid[src]) begin
        exp_winner = src;
      end
    end
    if (winner >= 0 && winner != exp_winner) begin
      err($sformatf("priority: source %0d accepted while %0d valid", winner, exp_winner));
    end

    if ((sram_rd_req || sram_wr_req) != (winner >= 0)) begin
      err("SRAM request does not match a handshake");
    end

    if (winner < 0) begin
      if (sram_req_ready && exp_winner >= 0) begin
        n_conflict_stalls++;
        if (BankBusyCycles == 0) begin
          err("request stalled with no conflict possible");
        end
      end
      return;
    end

    // The SRAM request matches the accepted request.
    if (!sram_req_ready) begin
      err("request issued while sram_req_ready = 0");
    end
    if (sram_tag != req_tag_e'(winner)) begin
      err($sformatf("tag %0d for source %0d", sram_tag, winner));
    end
    if (sram_wr_req != req_is_write[winner]) begin
      err("read/write direction mismatch");
    end
    if (sram_addr != exp_sram_addr(winner)) begin
      err($sformatf("address %h, expected %h", sram_addr, exp_sram_addr(winner)));
    end
    if (sram_transpose != (src_is_vec(winner) ? vec_req_transpose : 1'b0)) begin
      err("transpose mismatch");
    end
    if (sram_transpose) begin
      n_transpose++;
    end

    // Bank-group spacing.
    groups = groups_of(winner);
    for (int unsigned group = 0; group < NUM_LANES; group++) begin
      if (groups[group]) begin
        if (cycle - last_issue[group] <= longint'(BankBusyCycles)) begin
          err($sformatf("bank group %0d reused after %0d cycles", group, cycle - last_issue[group]
              ));
        end
        last_issue[group] = cycle;
      end
    end

    // Reference model.
    n_accepted[winner]++;
    if (req_is_write[winner]) begin
      logic [WR_BE_WIDTH-1:0] be;
      logic [ DATA_WIDTH-1:0] data;
      be   = exp_be(winner);
      data = exp_wdata_row(winner);
      if (sram_wr_be != be) begin
        err($sformatf("byte enables wrong for source %0d", winner));
      end
      for (int unsigned b = 0; b < ROW_BYTES; b++) begin
        if (be[b] && sram_wdata[8*b+:8] != data[8*b+:8]) begin
          err($sformatf("write data byte %0d wrong for source %0d", b, winner));
          break;
        end
      end
      if (!sram_transpose) begin
        for (int unsigned b = 0; b < ROW_BYTES; b++) begin
          if (be[b]) begin
            ref_mem[sram_addr[ROW_OFFSET_BITS+:ROW_IDX_BITS]][8*b+:8] = data[8*b+:8];
          end
        end
      end
      pend_wr[winner]++;
    end else begin
      logic [EXP_IDX_BITS-1:0] slot;
      if (sram_wr_be != '0) begin
        err("byte enables set on a read");
      end
      if (exp_count[winner] == EXP_DEPTH) begin
        err("expected-read buffer overflow");
      end
      slot                       = exp_head[winner] + EXP_IDX_BITS'(exp_count[winner]);
      exp_rd_buf[winner][slot]   = ref_mem[sram_addr[ROW_OFFSET_BITS+:ROW_IDX_BITS]];
      exp_rd_check[winner][slot] = !sram_transpose;  // transpose is not modelled
      exp_count[winner]++;
      pend_rd[winner]++;
    end
  endtask

  task automatic check_responses();
    logic [NUM_SOURCES-1:0] rsp_vec;
    logic [ DATA_WIDTH-1:0] got;
    logic [ DATA_WIDTH-1:0] exp_row;
    bit                     do_check;

    rsp_vec = {vec_rsp_valid, matrix_rsp_valid, mm_rsp_valid};
    if (!$onehot0(rsp_vec)) begin
      err("more than one rsp_valid");
    end

    for (int unsigned src = 0; src < NUM_SOURCES; src++) begin
      if (rsp_vec[src]) begin
        if (!(sb_rd_done && sb_rd_tag == req_tag_e'(src))) begin
          err("rsp_valid without matching sb_rd_done");
        end
        if (exp_count[src] == 0) begin
          err($sformatf("unexpected read response to source %0d", src));
        end else begin
          exp_row       = exp_rd_buf[src][exp_head[src]];
          do_check      = exp_rd_check[src][exp_head[src]];
          exp_head[src] = exp_head[src] + 1'b1;
          exp_count[src]--;
          n_rd_rsp[src]++;
          if (src == SRC_MM) begin
            got = mm_rsp_rdata;
          end else if (src == SRC_MATRIX) begin
            got = matrix_rsp_rdata;
          end else begin
            got = DATA_WIDTH'(vec_rsp_rdata[lane_of(src)]);
          end
          if (!do_check) begin
            n_unchecked++;
          end else if (src_is_vec(src)) begin
            if (got[LANE_DATA_WIDTH-1:0] != exp_row[lane_of(
                    src
                )*LANE_DATA_WIDTH+:LANE_DATA_WIDTH]) begin
              err($sformatf("read data mismatch, Vector lane %0d", lane_of(src)));
            end
          end else if (got != exp_row) begin
            err($sformatf("read data mismatch, source %0d", src));
          end
        end
      end
    end

    if (sb_rd_done) begin
      if (pend_rd[int'(sb_rd_tag)] == 0) begin
        err($sformatf("extra sb_rd_done for tag %0d", sb_rd_tag));
      end else begin
        pend_rd[int'(sb_rd_tag)]--;
      end
      if (!rsp_valid_for(sb_rd_tag)) begin
        err("sb_rd_done without engine response");
      end
    end
    if (sb_wr_done) begin
      if (pend_wr[int'(sb_wr_tag)] == 0) begin
        err($sformatf("extra sb_wr_done for tag %0d", sb_wr_tag));
      end else begin
        pend_wr[int'(sb_wr_tag)]--;
        n_wr_cpl[int'(sb_wr_tag)]++;
      end
    end
    if (sb_rd_done && sb_wr_done) begin
      err("read and write completion in the same cycle");
    end
  endtask

  task automatic sample_and_check();
    check_handshake_and_issue();
    check_responses();
  endtask

  // ---------------------------------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------------------------------
  // After the clock edge: drop accepted requests, start new ones, and drive the ports.
  task automatic update_sources();
    for (int unsigned src = 0; src < NUM_SOURCES; src++) begin
      if (accepted[src]) begin
        req_valid[src] = 1'b0;
      end
      if (!req_valid[src] && (!transpose_mode || src_is_vec(
              src
          )) && ($urandom_range(
              99
          ) < valid_pct)) begin
        new_request(src);
      end
    end
    vec_req_transpose = transpose_mode;
    sram_req_ready    = ($urandom_range(99) < ready_pct);
    drive_ports();
  endtask

  task automatic run_cycles(int unsigned n);
    repeat (n) begin
      @(negedge clk);
      sample_and_check();
      @(posedge clk);
      #1;
      cycle++;
      update_sources();
    end
  endtask

  // Stop new requests and let everything outstanding complete.
  task automatic drain();
    valid_pct = 0;
    ready_pct = 100;
    run_cycles(200);
  endtask

  task automatic check_drained(string test_name);
    for (int unsigned src = 0; src < NUM_SOURCES; src++) begin
      if (req_valid[src] || exp_count[src] != 0 || pend_rd[src] != 0 || pend_wr[src] != 0) begin
        err($sformatf("%s: source %0d has outstanding work after drain", test_name, src));
      end
    end
  endtask

  task automatic apply_reset(int unsigned n_cycles);
    @(posedge clk);
    #1;
    rst_n = 1'b0;
    clear_tracking();
    sram_req_ready = 1'b0;
    drive_ports();
    repeat (n_cycles) begin
      @(negedge clk);
      if (sram_rd_req || sram_wr_req || sb_rd_done || sb_wr_done || mm_rsp_valid ||
          matrix_rsp_valid || (vec_rsp_valid != '0)) begin
        err("activity during reset");
      end
    end
    @(posedge clk);
    #1;
    rst_n = 1'b1;
  endtask

  // Memory Manager burst: 16 write beats then 16 read beats while the other sources keep
  // requesting. With sram_req_ready = 1 and no bank-busy time, every beat is accepted in
  // consecutive cycles.
  task automatic test_mm_burst();
    int unsigned base_row;
    $display("Test: Memory Manager burst");
    ready_pct      = 100;
    valid_pct      = 100;
    base_row       = 0;
    sram_req_ready = 1'b1;
    for (int unsigned dir = 0; dir < 2; dir++) begin
      int unsigned beat;
      int unsigned wait_cycles;
      beat        = 0;
      wait_cycles = 0;
      while (beat < 16) begin
        if (!req_valid[SRC_MM]) begin
          req_valid[SRC_MM]    = 1'b1;
          req_is_write[SRC_MM] = (dir == 0);
          req_addr[SRC_MM]     = ADDR_WIDTH'((base_row + beat) % NUM_ROWS) << ROW_OFFSET_BITS;
          req_wdata[SRC_MM]    = rand_row();
          req_size[SRC_MM]     = SIZE_WIDTH'(ROW_BYTES);
        end
        drive_ports();
        @(negedge clk);
        sample_and_check();
        if (accepted[SRC_MM]) begin
          beat++;
        end else begin
          wait_cycles++;
        end
        @(posedge clk);
        #1;
        cycle++;
        for (int unsigned src = 0; src < NUM_SOURCES; src++) begin
          if (accepted[src]) begin
            req_valid[src] = 1'b0;
          end
          if (src != SRC_MM && !req_valid[src]) begin
            new_request(src);
          end
        end
        vec_req_transpose = 1'b0;
        sram_req_ready    = 1'b1;
      end
      if (BankBusyCycles == 0 && wait_cycles != 0) begin
        err($sformatf("burst: %0d stall cycles with sram_req_ready = 1", wait_cycles));
      end
      $display("  %s burst: 16 beats in %0d cycles", (dir == 0) ? "write" : "read",
               16 + wait_cycles);
    end
    drive_ports();
    drain();
    check_drained("burst");
  endtask

  task automatic test_random(int unsigned n_cycles, int unsigned v_pct, int unsigned r_pct);
    $display("Test: random traffic, %0d cycles, valid %0d%%, SRAM ready %0d%%", n_cycles, v_pct,
             r_pct);
    valid_pct = v_pct;
    ready_pct = r_pct;
    run_cycles(n_cycles);
    drain();
    check_drained("random");
  endtask

  // Reset in the middle of traffic: no stale responses or completions afterwards.
  task automatic test_reset_mid_traffic();
    $display("Test: reset during traffic");
    valid_pct = 60;
    ready_pct = 100;
    run_cycles(50);
    apply_reset(3);
    valid_pct = 0;
    run_cycles(SramLatency + 10);
    check_drained("reset");
    test_random(500, 50, 90);
  endtask

  // Transpose pass-through: Vector reads with vec_req_transpose_i = 1.
  task automatic test_transpose();
    $display("Test: transpose pass-through (data not checked, not modelled)");
    transpose_mode = 1'b1;
    test_random(300, 60, 100);
    transpose_mode = 1'b0;
    vec_req_transpose = 1'b0;
  endtask

  // Invalid inputs: misaligned addresses, Matrix size 0 and > 512, and an illegal response tag.
  task automatic test_invalid();
    $display("Test: invalid inputs");
    invalid_mode = 1'b1;
    test_random(3000, 40, 80);
    invalid_mode = 1'b0;

    // Illegal response tag on an otherwise idle response port: must be dropped.
    @(posedge clk);
    #1;
    inject_rsp = 1'b1;
    inject_tag = TAG_WIDTH'(7);
    @(negedge clk);
    if (sb_rd_done || sb_wr_done || mm_rsp_valid || matrix_rsp_valid || (vec_rsp_valid != '0)) begin
      err("response with an illegal tag was not dropped");
    end
    @(posedge clk);
    #1;
    inject_rsp = 1'b0;
  endtask

  // ---------------------------------------------------------------------------------------------
  // Main sequence
  // ---------------------------------------------------------------------------------------------
  initial begin
    errors            = 0;
    cycle             = 0;
    n_conflict_stalls = 0;
    n_transpose       = 0;
    n_unchecked       = 0;
    transpose_mode    = 1'b0;
    invalid_mode      = 1'b0;
    valid_pct         = 0;
    ready_pct         = 0;
    inject_rsp        = 1'b0;
    inject_tag        = '0;
    vec_req_transpose = 1'b0;
    sram_req_ready    = 1'b0;
    rst_n             = 1'b1;
    for (int unsigned src = 0; src < NUM_SOURCES; src++) begin
      req_is_write[src] = 1'b0;
      req_addr[src]     = '0;
      req_wdata[src]    = '0;
      req_size[src]     = '0;
      n_accepted[src]   = 0;
      n_rd_rsp[src]     = 0;
      n_wr_cpl[src]     = 0;
    end
    clear_tracking();
    drive_ports();

    apply_reset(5);

    if (TestInvalid) begin
      test_invalid();
    end else begin
      test_mm_burst();
      test_random(RandomCycles, 40, 80);
      test_random(2000, 100, 100);
      test_reset_mid_traffic();
      test_transpose();
      if (n_accepted[NUM_SOURCES-1] == 0) begin
        err("Vector lane 3 never served");
      end
    end

    for (int unsigned src = 0; src < NUM_SOURCES; src++) begin
      $display("  source %0d: %0d accepted, %0d read responses, %0d write completions", src,
               n_accepted[src], n_rd_rsp[src], n_wr_cpl[src]);
    end
    $display("  conflict stalls: %0d, transposed requests: %0d, reads not data-checked: %0d",
             n_conflict_stalls, n_transpose, n_unchecked);

    if (errors == 0) begin
      $display("PASS: sram_arbiter_tb (BankBusyCycles=%0d, SramLatency=%0d, TestInvalid=%0d)",
               BankBusyCycles, SramLatency, TestInvalid);
    end else begin
      $display("FAIL: %0d errors", errors);
    end
    $finish;
  end

  initial begin
    #(TIMEOUT_CYCLES * 10ns);
    $display("FAIL: timeout");
    $finish;
  end

endmodule
