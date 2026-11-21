// Integration testbench for bpu_matrix_unit in the control and memory system it plugs
// into: the real command_queues and shared_scoreboard (rtl/control, from rtl main at
// 8ca0677) with three queues and 16-bit counters, bpu_matrix_unit on the Matrix queue,
// sram_arbiter_spec_model (the arbiter as specified, with the SRAM) on the Matrix
// channel, and two stand-in units written here: a Memory unit that decodes the Memory
// specification's TRANSFER record and writes full rows from an HBM image, and a
// Vector unit that reads rows back for checking. The testbench plays the controller:
// it pushes records with their sideband wait targets in program order, latches engine
// faults, decides completion the way the controller does (the final targets reached,
// every queue empty, every engine idle) and applies the coordinated reset.
//
// The queue's Matrix issue port connects straight to the unit, without the
// controller's fault gate, so after a fault the unit itself must refuse the next offer.
//
// Parameters: StallPct (the arbiter's random busy cycles), MemDelayMax (cycles of HBM
// latency per row, chosen at random up to this), Seed. Plusargs:
//   +seed=<n>       random seed (default: Seed)
//   +inject_error=1 corrupt one expected byte on purpose; the run must FAIL
//
// Jobs (each starts from the coordinated reset)
//   A. full     Memory loads the golden operand image (92 rows) in three transfers, the
//               first a single row; Matrix runs the five golden commands, each waiting
//               for the last load; Vector reads a junk region at the same time (waiting
//               for the loads); a fourth transfer waits for the last Matrix command's
//               first milestone (inputs released) and then overwrites that command's
//               B operand, so a release before the last read would corrupt its C; a
//               second Vector run waits for Matrix complete (target 15) and reads the
//               whole C region back.
//   B. fault    two loads and a single-row load, then Matrix: a legal command, a record
//               with version 2, another legal command; a Vector run waits for Matrix
//               target 9, which never comes. The fault must reach the controller, the
//               third Matrix record must stay offered and unaccepted, Matrix must stop
//               all SRAM traffic, and the first command's C must be right.
//   C. reset    job A without its last three records, reset once the first Matrix
//               command has released its inputs.
//   A again     after B and C, on the same hardware: recovery is complete.
//
// Checks: the operand region starts as junk and the C region as 0xA5, so a read
// before its load or a missing write shows. At each Matrix and Vector issue, the
// scoreboard's progress has reached the command's targets (the queue's gating, seen
// from outside). At completion: progress equals the targets exactly, no write is in
// flight, every byte of the C region is right in the SRAM and in what the Vector run
// read, and for 16 more cycles no request is made and progress does not move. Every
// cycle: no engine or arbiter fault outside job B, matrix requests never use the
// transpose view. The arbiter model checks the request protocol. The run ends with
// $fatal(1, ...) on any error, a count mismatch or a timeout and prints one RESULT line.
module bpu_matrix_unit_system_tb;
  timeunit 1ns; timeprecision 1ps;
  import bpu_sa_pkg::*;
  import bpu_sa_golden_vectors_pkg::*;
  import bpu_matrix_record_tb_pkg::*;

  parameter int StallPct = 20;
  parameter int MemDelayMax = 6;
  parameter int Seed = 1;

  localparam int COUNTER_WIDTH = 16;
  localparam int PAYLOAD_WIDTH = RECORD_W;  // the Matrix version-1 record
  localparam int ROW_BYTES = GV_ROW_BYTES;
  localparam int DATA_WIDTH = 8 * ROW_BYTES;
  localparam int SIZE_WIDTH = $clog2(ROW_BYTES) + 1;
  localparam int OPERAND_ROWS = GV_C_LO / ROW_BYTES;  // golden image rows before the C region
  localparam int JUNK_ROW = 100;  // a region nothing else uses, for the background Vector read
  localparam int JUNK_ROWS = 24;
  localparam int MEM_ROWS = JUNK_ROW + JUNK_ROWS;
  localparam int MEM_BYTES = MEM_ROWS * ROW_BYTES;
  localparam int HBM_JUNK = 128;  // HBM rows of junk, for the overwriting transfer
  localparam int HBM_ROWS = HBM_JUNK + 32;
  localparam int JOB_TIMEOUT = 60000 * 100 / (100 - StallPct);
  localparam int TIMEOUT_CYCLES = 6 * JOB_TIMEOUT;

  // Queue, counter and arbiter channel indices
  localparam int MEMORY = 0;
  localparam int MATRIX = 1;
  localparam int VECTOR = 2;

  // Memory and Vector records (docs/memory/memory_unit_spec.md and the Vector stand-in
  // below): the kind, two wait targets, then the body; bits above the body are zero.
  localparam logic [1:0] KIND_TRANSFER = 2'b00;
  localparam logic [1:0] KIND_VECTOR_RUN = 2'b10;
  localparam int TARGET_0_LSB = 2;
  localparam int TARGET_1_LSB = TARGET_0_LSB + COUNTER_WIDTH;
  localparam int HEADER_BITS = TARGET_1_LSB + COUNTER_WIDTH;
  localparam logic TRANSFER_LOAD = 1'b0;
  localparam int TRANSFER_DIRECTION_BIT = HEADER_BITS;
  localparam int TRANSFER_HBM_LSB = HEADER_BITS + 1;  // 34-bit byte address
  localparam int TRANSFER_SRAM_LSB = TRANSFER_HBM_LSB + 34;
  localparam int TRANSFER_LENGTH_LSB = TRANSFER_SRAM_LSB + 32;  // bytes
  localparam int TRANSFER_BITS = TRANSFER_LENGTH_LSB + 32;
  localparam logic [7:0] RUN_READ = 8'd1;  // the one operation the stand-in runs
  localparam int RUN_OPERATION_LSB = HEADER_BITS;
  localparam int RUN_SRAM_LSB = RUN_OPERATION_LSB + 8;
  localparam int RUN_BYTES_LSB = RUN_SRAM_LSB + 32;
  localparam int RUN_BITS = RUN_BYTES_LSB + 32;

  logic clk;
  logic rst_n;

  // Command queues
  logic push_valid[3];
  logic push_ready[3];
  logic [PAYLOAD_WIDTH-1:0] push_payload[3];
  logic [COUNTER_WIDTH-1:0] push_t0[3];
  logic [COUNTER_WIDTH-1:0] push_t1[3];
  logic issue_valid[3];
  logic issue_ready[3];
  logic [PAYLOAD_WIDTH-1:0] issue_payload[3];
  logic [1:0] increment[3];
  logic [COUNTER_WIDTH-1:0] progress[3];
  logic engine_idle[3];
  logic engine_fault[3];

  // Matrix unit and its channel
  logic mx_ready;
  logic [1:0] mx_inc;
  logic mx_idle;
  logic mx_fault;
  logic mx_req_valid;
  logic mx_req_ready;
  logic mx_req_is_write;
  logic [SIZE_WIDTH-1:0] mx_req_size;
  logic [31:0] mx_req_addr;
  logic [DATA_WIDTH-1:0] mx_req_wdata;
  logic mx_req_transpose;
  logic [1:0] mx_req_element_width;
  logic mx_rsp_valid;
  logic [DATA_WIDTH-1:0] mx_rsp_rdata;

  // Memory stand-in
  logic mu_req_valid;
  logic mu_req_ready;
  logic [31:0] mu_req_addr;
  logic [DATA_WIDTH-1:0] mu_req_wdata;
  logic mu_rsp_valid;
  logic [DATA_WIDTH-1:0] mu_rsp_rdata;
  logic mu_active;
  logic [33:0] mu_hbm;
  logic [31:0] mu_sram;
  int mu_rows;
  int mu_row;
  int mu_delay;
  logic [1:0] mu_inc;

  // Vector stand-in
  logic vu_req_valid;
  logic vu_req_ready;
  logic [SIZE_WIDTH-1:0] vu_req_size;
  logic [31:0] vu_req_addr;
  logic vu_rsp_valid;
  logic [DATA_WIDTH-1:0] vu_rsp_rdata;
  logic vu_active;
  logic [31:0] vu_base;
  int vu_bytes;
  int vu_next;  // next byte offset to request
  int vu_pending;  // reads accepted, response not yet back
  logic [31:0] vu_rsp_addr;  // the address of the read now returning
  logic [SIZE_WIDTH-1:0] vu_rsp_size;
  logic [1:0] vu_inc;
  logic [1:0] vu_due;  // milestones decided, published next cycle

  logic arb_fault;
  int accepted[3];
  int waited[3];
  int model_errors;

  logic [DATA_WIDTH-1:0] hbm[HBM_ROWS];
  logic [7:0] vec_seen[MEM_BYTES];  // last byte the Vector stand-in read at each address

  // Controller-side bookkeeping, reset with everything else
  int pushed[3];
  int issued[3];
  logic [COUNTER_WIDTH-1:0] issue_t0_q[3][$];  // targets of the records still in each queue
  logic [COUNTER_WIDTH-1:0] issue_t1_q[3][$];
  bit fault_seen;
  bit fault_expected;

  int b4_row;  // the last command's B operand: 32 rows from here
  int cycle;
  int seed;
  int unsigned rng;
  int inject_arg;
  bit inject_error;
  int errors;
  int stub_errors;
  int jobs_done;
  int bytes_checked;
  int gating_checks;
  int blocked_offer_cycles;
  int resets;
  string status;

  // ---------------------------------------------------------------------------
  // The design
  // ---------------------------------------------------------------------------
  command_queues #(
    .QueueDepth  (4),
    .PayloadWidth(PAYLOAD_WIDTH),
    .CounterWidth(COUNTER_WIDTH),
    .NumQueues   (3),
    .NumCounters (3)
  ) u_queues (
    .clk_i               (clk),
    .rst_ni              (rst_n),
    .push_valid_i        (push_valid),
    .push_ready_o        (push_ready),
    .push_payload_i      (push_payload),
    .push_wait_target_0_i(push_t0),
    .push_wait_target_1_i(push_t1),
    .issue_valid_o       (issue_valid),
    .issue_ready_i       (issue_ready),
    .issue_payload_o     (issue_payload),
    .increment_i         (increment),
    .progress_o          (progress)
  );

  bpu_matrix_unit #(
    .PayloadWidth(PAYLOAD_WIDTH),
    .Rows        (GV_ROWS),
    .Cols        (GV_COLS),
    .DataW       (DATA_WIDTH),
    .SizeW       (SIZE_WIDTH),
    .BlockK      (GV_BLOCK_K)
  ) u_matrix (
    .clk_i                     (clk),
    .rst_ni                    (rst_n),
    .cmd_valid_i               (issue_valid[MATRIX]),
    .cmd_ready_o               (mx_ready),
    .cmd_payload_i             (issue_payload[MATRIX]),
    .milestone_inc_o           (mx_inc),
    .idle_o                    (mx_idle),
    .fault_o                   (mx_fault),
    .matrix_req_valid_o        (mx_req_valid),
    .matrix_req_ready_i        (mx_req_ready),
    .matrix_req_is_write_o     (mx_req_is_write),
    .matrix_req_size_bytes_o   (mx_req_size),
    .matrix_req_addr_o         (mx_req_addr),
    .matrix_req_wdata_o        (mx_req_wdata),
    .matrix_req_transpose_o    (mx_req_transpose),
    .matrix_req_element_width_o(mx_req_element_width),
    .matrix_rsp_valid_i        (mx_rsp_valid),
    .matrix_rsp_rdata_i        (mx_rsp_rdata)
  );

  sram_arbiter_spec_model #(
    .AddrW   (32),
    .DataW   (DATA_WIDTH),
    .SizeW   (SIZE_WIDTH),
    .MemBytes(MEM_BYTES),
    .StallPct(StallPct)
  ) u_arbiter (
    .clk_i                     (clk),
    .rst_ni                    (rst_n),
    .mm_req_valid_i            (mu_req_valid),
    .mm_req_ready_o            (mu_req_ready),
    .mm_req_is_write_i         (1'b1),
    .mm_req_addr_i             (mu_req_addr),
    .mm_req_wdata_i            (mu_req_wdata),
    .mm_rsp_valid_o            (mu_rsp_valid),
    .mm_rsp_rdata_o            (mu_rsp_rdata),
    .matrix_req_valid_i        (mx_req_valid),
    .matrix_req_ready_o        (mx_req_ready),
    .matrix_req_is_write_i     (mx_req_is_write),
    .matrix_req_size_bytes_i   (mx_req_size),
    .matrix_req_addr_i         (mx_req_addr),
    .matrix_req_wdata_i        (mx_req_wdata),
    .matrix_req_transpose_i    (mx_req_transpose),
    .matrix_req_element_width_i(mx_req_element_width),
    .matrix_rsp_valid_o        (mx_rsp_valid),
    .matrix_rsp_rdata_o        (mx_rsp_rdata),
    .vec_req_valid_i           (vu_req_valid),
    .vec_req_ready_o           (vu_req_ready),
    .vec_req_is_write_i        (1'b0),
    .vec_req_size_bytes_i      (vu_req_size),
    .vec_req_addr_i            (vu_req_addr),
    .vec_req_wdata_i           ('0),
    .vec_rsp_valid_o           (vu_rsp_valid),
    .vec_rsp_rdata_o           (vu_rsp_rdata),
    .fault_o                   (arb_fault),
    .accepted_o                (accepted),
    .waited_o                  (waited),
    .errors_o                  (model_errors)
  );

  // The controller's unit ports
  assign issue_ready[MEMORY] = !mu_active && mu_inc == '0;
  assign issue_ready[MATRIX] = mx_ready;
  assign issue_ready[VECTOR] = !vu_active && vu_inc == '0 && vu_due == '0;
  assign increment[MEMORY] = mu_inc;
  assign increment[MATRIX] = mx_inc;
  assign increment[VECTOR] = vu_inc;
  assign engine_idle[MEMORY] = !mu_active && mu_inc == '0;
  assign engine_idle[MATRIX] = mx_idle;
  assign engine_idle[VECTOR] = !vu_active && vu_inc == '0 && vu_due == '0;
  assign engine_fault[MEMORY] = 1'b0;
  assign engine_fault[MATRIX] = mx_fault;
  assign engine_fault[VECTOR] = 1'b0;

  // ---------------------------------------------------------------------------
  // Memory stand-in: one TRANSFER at a time, loads only. Each 512-byte row is written
  // after a random HBM delay. Milestone 1 when the first row's write commits, milestone 2 when
  // the last row's does (both together for a one-row load), published so the queue
  // counts them on the commit edge.
  // ---------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mu_active    <= 1'b0;
      mu_req_valid <= 1'b0;
      mu_inc       <= '0;
    end else begin
      mu_inc <= '0;
      if (issue_valid[MEMORY] && issue_ready[MEMORY]) begin
        logic [PAYLOAD_WIDTH-1:0] p;
        p = issue_payload[MEMORY];
        if (p[KIND_LSB+:2] != KIND_TRANSFER || p[TRANSFER_DIRECTION_BIT] != TRANSFER_LOAD
            || p[TRANSFER_LENGTH_LSB+:32] == 0 || p[TRANSFER_LENGTH_LSB+:32] % ROW_BYTES != 0
            || p[TRANSFER_SRAM_LSB+:32] % ROW_BYTES != 0
            || p[PAYLOAD_WIDTH-1:TRANSFER_BITS] != '0) begin
          stub_errors++;
          $display("bpu_matrix_unit_system_tb: Memory stand-in got a bad record");
        end
        mu_active <= 1'b1;
        mu_hbm    <= p[TRANSFER_HBM_LSB+:34];
        mu_sram   <= p[TRANSFER_SRAM_LSB+:32];
        mu_rows   <= int'(p[TRANSFER_LENGTH_LSB+:32]) / ROW_BYTES;
        mu_row    <= 0;
        mu_delay  <= int'(rand32() % (MemDelayMax + 1));
      end else if (mu_active) begin
        if (mu_req_valid && mu_req_ready) begin
          mu_req_valid <= 1'b0;
          mu_inc       <= 2'((mu_row == 0) ? 1 : 0) + 2'((mu_row == mu_rows - 1) ? 1 : 0);
          mu_row       <= mu_row + 1;
          mu_delay     <= int'(rand32() % (MemDelayMax + 1));
          if (mu_row == mu_rows - 1) begin
            mu_active <= 1'b0;
          end
        end else if (!mu_req_valid) begin
          if (mu_delay > 0) begin
            mu_delay <= mu_delay - 1;
          end else begin
            mu_req_valid <= 1'b1;
            mu_req_addr  <= mu_sram + 32'(ROW_BYTES * mu_row);
            mu_req_wdata <= hbm[int'(mu_hbm/ROW_BYTES)+mu_row];
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Vector stand-in: one VECTOR_RUN at a time, operation RUN_READ only. It reads the
  // range a row at a time (the last read only the bytes left) and records each byte in
  // vec_seen. Milestone 1 when every read has been accepted, milestone 2 when every
  // response is back.
  // ---------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      vu_active    <= 1'b0;
      vu_req_valid <= 1'b0;
      vu_inc       <= '0;
      vu_due       <= '0;
      vu_pending   <= 0;
    end else begin
      int pending;
      logic [1:0] due;
      bit start;
      bit done;
      pending = vu_pending;
      due     = '0;
      start   = issue_valid[VECTOR] && issue_ready[VECTOR];
      done    = 1'b0;
      vu_inc <= vu_due;
      if (vu_rsp_valid) begin
        for (int b = 0; b < int'(vu_rsp_size); b++) begin
          vec_seen[vu_rsp_addr+b] <= vu_rsp_rdata[8*b+:8];
        end
        pending--;
        if (pending == 0 && vu_next >= vu_bytes && !vu_req_valid) begin
          due += 2'd1;  // complete
          done = 1'b1;
        end
      end
      if (start) begin
        logic [PAYLOAD_WIDTH-1:0] p;
        p = issue_payload[VECTOR];
        if (p[KIND_LSB+:2] != KIND_VECTOR_RUN || p[RUN_OPERATION_LSB+:8] != RUN_READ
            || p[RUN_BYTES_LSB+:32] == 0 || p[RUN_SRAM_LSB+:32] % ROW_BYTES != 0
            || p[PAYLOAD_WIDTH-1:RUN_BITS] != '0) begin
          stub_errors++;
          $display("bpu_matrix_unit_system_tb: Vector stand-in got a bad record");
        end
        vu_base  <= p[RUN_SRAM_LSB+:32];
        vu_bytes <= int'(p[RUN_BYTES_LSB+:32]);
        vu_next  <= 0;
      end else if (vu_active && vu_req_valid && vu_req_ready) begin
        pending++;
        vu_rsp_addr  <= vu_req_addr;
        vu_rsp_size  <= vu_req_size;
        vu_req_valid <= 1'b0;
        if (vu_next >= vu_bytes) begin
          due += 2'd1;  // every read issued
        end
      end else if (vu_active && !vu_req_valid && vu_next < vu_bytes) begin
        int n;
        n = (vu_bytes - vu_next > ROW_BYTES) ? ROW_BYTES : vu_bytes - vu_next;
        vu_req_valid <= 1'b1;
        vu_req_addr  <= vu_base + 32'(vu_next);
        vu_req_size  <= SIZE_WIDTH'(n);
        vu_next      <= vu_next + n;
      end
      vu_pending <= pending;
      vu_due     <= due;
      vu_active  <= start || (vu_active && !done);
    end
  end

  // ---------------------------------------------------------------------------
  // The controller's bookkeeping and every-cycle checks
  // ---------------------------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int q = 0; q < 3; q++) begin
        pushed[q] <= 0;
        issued[q] <= 0;
        issue_t0_q[q].delete();
        issue_t1_q[q].delete();
      end
      fault_seen <= 1'b0;
    end else begin
      for (int q = 0; q < 3; q++) begin
        if (push_valid[q] && push_ready[q]) begin
          pushed[q] <= pushed[q] + 1;
          issue_t0_q[q].push_back(push_t0[q]);
          issue_t1_q[q].push_back(push_t1[q]);
        end
        if (issue_valid[q] && issue_ready[q]) begin
          logic [COUNTER_WIDTH-1:0] t0;
          logic [COUNTER_WIDTH-1:0] t1;
          int c0;
          int c1;
          issued[q] <= issued[q] + 1;
          t0 = issue_t0_q[q].pop_front();
          t1 = issue_t1_q[q].pop_front();
          // The queue's mapping: Memory waits on Matrix, Vector; Matrix on Memory,
          // Vector; Vector on Memory, Matrix.
          c0 = (q == MEMORY) ? MATRIX : MEMORY;
          c1 = (q == VECTOR) ? MATRIX : VECTOR;
          gating_checks++;
          if (!reached(progress[c0], t0) || !reached(progress[c1], t1)) begin
            errors++;
            $display("bpu_matrix_unit_system_tb: queue %0d issued before its targets %0d, %0d", q,
                     t0, t1);
          end
        end
      end
      if (engine_fault[MEMORY] || engine_fault[MATRIX] || engine_fault[VECTOR] || arb_fault) begin
        fault_seen <= 1'b1;
      end
    end
  end

  always @(negedge clk) begin
    cycle++;
    if (rst_n === 1'b1) begin
      if (!fault_expected && (mx_fault !== 1'b0 || arb_fault !== 1'b0)) begin
        errors++;
        $display("bpu_matrix_unit_system_tb: unexpected fault (matrix %b, arbiter %b) at cycle %0d",
                 mx_fault, arb_fault, cycle);
      end
      if (mx_req_valid === 1'b1 && (mx_req_transpose !== 1'b0 || mx_req_element_width !== 2'b00))
      begin
        errors++;
        $display("bpu_matrix_unit_system_tb: matrix request with transpose fields set");
      end
    end
  end

  function automatic bit reached(input logic [COUNTER_WIDTH-1:0] p,
                                 input logic [COUNTER_WIDTH-1:0] t);
    logic [COUNTER_WIDTH-1:0] delta;
    delta = p - t;
    return (t == '0) || !delta[COUNTER_WIDTH-1];
  endfunction

  function automatic int unsigned rand32();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  initial begin : clock
    clk = 1'b0;
    forever begin
      #5 clk = ~clk;
    end
  end

  initial begin : watchdog
    repeat (TIMEOUT_CYCLES) begin
      @(posedge clk);
    end
    $fatal(1, "bpu_matrix_unit_system_tb: timeout after %0d cycles", TIMEOUT_CYCLES);
  end

  // ---------------------------------------------------------------------------
  // Records
  // ---------------------------------------------------------------------------
  function automatic logic [PAYLOAD_WIDTH-1:0] transfer(input int hbm_row, input int sram_row,
                                                        input int rows, input int t0, input int t1);
    logic [PAYLOAD_WIDTH-1:0] r;
    r                              = '0;
    r[KIND_LSB+:2]                 = KIND_TRANSFER;
    r[TARGET_0_LSB+:COUNTER_WIDTH] = COUNTER_WIDTH'(t0);
    r[TARGET_1_LSB+:COUNTER_WIDTH] = COUNTER_WIDTH'(t1);
    r[TRANSFER_DIRECTION_BIT]      = TRANSFER_LOAD;
    r[TRANSFER_HBM_LSB+:34]        = 34'(hbm_row * ROW_BYTES);
    r[TRANSFER_SRAM_LSB+:32]       = 32'(sram_row * ROW_BYTES);
    r[TRANSFER_LENGTH_LSB+:32]     = 32'(rows * ROW_BYTES);
    return r;
  endfunction

  function automatic logic [PAYLOAD_WIDTH-1:0] vector_read(input int addr, input int bytes,
                                                           input int t0, input int t1);
    logic [PAYLOAD_WIDTH-1:0] r;
    r                              = '0;
    r[KIND_LSB+:2]                 = KIND_VECTOR_RUN;
    r[TARGET_0_LSB+:COUNTER_WIDTH] = COUNTER_WIDTH'(t0);
    r[TARGET_1_LSB+:COUNTER_WIDTH] = COUNTER_WIDTH'(t1);
    r[RUN_OPERATION_LSB+:8]        = RUN_READ;
    r[RUN_SRAM_LSB+:32]            = 32'(addr);
    r[RUN_BYTES_LSB+:32]           = 32'(bytes);
    return r;
  endfunction

  // Matrix records come from bpu_matrix_record_tb_pkg, with wait-target words equal to
  // the sideband targets (the controller's adapter keeps them consistent).

  // ---------------------------------------------------------------------------
  // The controller
  // ---------------------------------------------------------------------------
  task automatic tick();
    @(negedge clk);
  endtask

  // Push one record with its sideband targets; returns after the accepting edge.
  task automatic push(input int q, input logic [PAYLOAD_WIDTH-1:0] p, input int t0, input int t1);
    int waited_cycles;
    push_valid[q]   = 1'b1;
    push_payload[q] = p;
    push_t0[q]      = COUNTER_WIDTH'(t0);
    push_t1[q]      = COUNTER_WIDTH'(t1);
    waited_cycles   = 0;
    while (push_ready[q] !== 1'b1) begin
      tick();
      waited_cycles++;
      if (waited_cycles > JOB_TIMEOUT) begin
        $fatal(1, "bpu_matrix_unit_system_tb: queue %0d never took a record", q);
      end
    end
    tick();
    push_valid[q] = 1'b0;
  endtask

  task automatic coordinated_reset();
    #2;
    rst_n = 1'b0;
    repeat (3) begin
      tick();
    end
    rst_n = 1'b1;
    tick();
    for (int q = 0; q < 3; q++) begin
      if (progress[q] !== '0 || issue_valid[q] !== 1'b0 || push_ready[q] !== 1'b1
          || engine_idle[q] !== 1'b1 || engine_fault[q] !== 1'b0) begin
        errors++;
        $display("bpu_matrix_unit_system_tb: queue %0d or its unit not clean after reset", q);
      end
    end
  endtask

  // A fresh SRAM: junk operands, 0xA5 C region, junk background region.
  task automatic paint_sram();
    for (int a = 0; a < MEM_BYTES; a++) begin
      u_arbiter.mem[a] = (a >= GV_C_LO && a < GV_C_HI) ? 8'hA5 : 8'(rand32());
      vec_seen[a]      = 8'h00;
    end
  endtask

  // The C region the golden commands leave: each writing command's tile, 0xA5 between.
  function automatic logic [7:0] expected_c(input int a, input bit only_first);
    for (int n = 0; n < GV_COMMANDS; n++) begin
      int c;
      c = int'(GV_CMD[n][9]);
      if (GV_CMD[n][4] != 0 && (!only_first || n == 0) && a >= c && a < c + 4 * GV_ROWS * GV_COLS)
      begin
        return GV_C[n][(a-c)/4][8*((a-c)%4)+:8];
      end
    end
    return 8'hA5;
  endfunction

  // The controller's completion: final targets reached, queues empty, engines idle.
  // Then everything the job promised must be visible and stay still.
  task automatic finish(input int t_mem, input int t_mx, input int t_vec, input bit check_vector,
                        input string name);
    int waited_cycles;
    int acc0[3];
    waited_cycles = 0;
    while (!(int'(progress[MEMORY]) == t_mem && int'(progress[MATRIX]) == t_mx
             && int'(progress[VECTOR]) == t_vec && pushed[MEMORY] == issued[MEMORY]
             && pushed[MATRIX] == issued[MATRIX] && pushed[VECTOR] == issued[VECTOR]
             && engine_idle[MEMORY] && engine_idle[MATRIX] && engine_idle[VECTOR])) begin
      tick();
      waited_cycles++;
      if (waited_cycles > JOB_TIMEOUT) begin
        $fatal(1, "bpu_matrix_unit_system_tb: job %s never finished (progress %0d %0d %0d)", name,
               progress[MEMORY], progress[MATRIX], progress[VECTOR]);
      end
    end
    if (u_arbiter.pend_q !== 1'b0) begin
      errors++;
      $display("bpu_matrix_unit_system_tb: job %s finished with a write in flight", name);
    end
    for (int a = GV_C_LO; a < GV_C_HI; a++) begin
      logic [7:0] want;
      want = expected_c(a, 1'b0);
      if (inject_error && jobs_done == 0 && a == GV_C_LO) begin
        want = want ^ 8'h01;
      end
      bytes_checked++;
      if (u_arbiter.mem[a] !== want || (check_vector && vec_seen[a] !== want)) begin
        errors++;
        if (errors <= 10) begin
          $display("bpu_matrix_unit_system_tb: job %s byte %0d: SRAM %h, Vector saw %h, want %h",
                   name, a, u_arbiter.mem[a], vec_seen[a], want);
        end
      end
    end
    for (int c = 0; c < 3; c++) begin
      acc0[c] = accepted[c];
    end
    repeat (16) begin
      tick();
      if (int'(progress[MEMORY]) != t_mem || int'(progress[MATRIX]) != t_mx
          || int'(progress[VECTOR]) != t_vec) begin
        errors++;
        $display("bpu_matrix_unit_system_tb: job %s: progress moved after completion", name);
      end
    end
    for (int c = 0; c < 3; c++) begin
      if (accepted[c] != acc0[c]) begin
        errors++;
        $display("bpu_matrix_unit_system_tb: job %s: SRAM traffic on channel %0d after completion",
                 name, c);
      end
    end
    jobs_done++;
    $display("JOB %s finished at cycle %0d", name, cycle);
  endtask

  // Job A, in program order. With full = 0, only the first eight records (for job C).
  task automatic job_a(input bit full);
    push(MEMORY, transfer(0, 0, 1, 0, 0), 0, 0);  // single row: both milestones at once
    push(MEMORY, transfer(1, 1, 39, 0, 0), 0, 0);
    push(MEMORY, transfer(40, 40, OPERAND_ROWS - 40, 0, 0), 0, 0);  // loads complete: target 6
    push(VECTOR, vector_read(JUNK_ROW * ROW_BYTES, JUNK_ROWS * ROW_BYTES, 6, 0), 6, 0);
    for (int n = 0; n < (full ? GV_COMMANDS : 4); n++) begin
      push(MATRIX, matrix_record(n, 8'd1, 6, 0), 6, 0);
    end
    if (full) begin
      // Overwrite the last command's B once it has released its inputs (3 * 4 + 1).
      push(MEMORY, transfer(HBM_JUNK, b4_row, 32, 13, 0), 13, 0);
      push(VECTOR, vector_read(GV_C_LO, GV_C_HI - GV_C_LO, 0, 15), 0, 15);
    end
  endtask

  initial begin : main
    if (!$value$plusargs("seed=%d", seed)) begin
      seed = Seed;
    end
    if (!$value$plusargs("inject_error=%d", inject_arg)) begin
      inject_arg = 0;
    end
    inject_error         = (inject_arg != 0);
    b4_row               = int'(GV_CMD[4][6]) / ROW_BYTES;
    rng                  = 32'h2545_F491 ^ seed;
    errors               = 0;
    stub_errors          = 0;
    jobs_done            = 0;
    bytes_checked        = 0;
    gating_checks        = 0;
    blocked_offer_cycles = 0;
    resets               = 0;
    cycle                = 0;
    fault_expected       = 1'b0;
    for (int q = 0; q < 3; q++) begin
      push_valid[q]   = 1'b0;
      push_payload[q] = '0;
      push_t0[q]      = '0;
      push_t1[q]      = '0;
    end
    for (int r = 0; r < HBM_ROWS; r++) begin
      if (r < OPERAND_ROWS) begin
        hbm[r] = GV_MEM[r];
      end else begin
        for (int w = 0; w < DATA_WIDTH / 32; w++) begin
          hbm[r][32*w+:32] = rand32();
        end
      end
    end
    rst_n = 1'b0;
    paint_sram();
    repeat (2) begin
      tick();
    end
    rst_n = 1'b1;
    tick();

    // A. The full job.
    job_a(1'b1);
    finish(8, 3 * GV_COMMANDS, 4, 1'b1, "A");

    // B. A malformed Matrix record between two legal ones.
    coordinated_reset();
    resets++;
    paint_sram();
    fault_expected = 1'b1;
    push(MEMORY, transfer(0, 0, 1, 0, 0), 0, 0);
    push(MEMORY, transfer(1, 1, 39, 0, 0), 0, 0);
    push(MEMORY, transfer(40, 40, OPERAND_ROWS - 40, 0, 0), 0, 0);
    push(MATRIX, matrix_record(0, 8'd1, 6, 0), 6, 0);
    push(MATRIX, matrix_record(4, 8'd2, 6, 0), 6, 0);
    push(MATRIX, matrix_record(1, 8'd1, 6, 0), 6, 0);
    push(VECTOR, vector_read(GV_C_LO, GV_C_HI - GV_C_LO, 0, 9), 0, 9);
    begin
      int waited_cycles;
      int mx0;
      waited_cycles = 0;
      while (fault_seen !== 1'b1) begin
        tick();
        waited_cycles++;
        if (waited_cycles > JOB_TIMEOUT) begin
          $fatal(1, "bpu_matrix_unit_system_tb: the malformed record never faulted");
        end
      end
      mx0 = accepted[MATRIX];
      repeat (300) begin
        tick();
        if (issue_valid[MATRIX] === 1'b1 && issue_ready[MATRIX] === 1'b0) begin
          blocked_offer_cycles++;
        end
      end
      if (accepted[MATRIX] != mx0 || int'(progress[MATRIX]) != 3 || int'(progress[MEMORY]) != 6
          || issued[MATRIX] != 2 || issue_valid[VECTOR] !== 1'b0 || mx_fault !== 1'b1
          || mx_idle !== 1'b1) begin
        errors++;
        $display(
          "bpu_matrix_unit_system_tb: job B: %0d matrix requests after the fault, %s %0d %0d %0d",
          accepted[MATRIX] - mx0, "progress", progress[MEMORY], progress[MATRIX], progress[VECTOR]);
      end
      for (int a = GV_C_LO; a < GV_C_HI; a++) begin
        bytes_checked++;
        if (u_arbiter.mem[a] !== expected_c(a, 1'b1)) begin
          errors++;
          if (errors <= 10) begin
            $display("bpu_matrix_unit_system_tb: job B byte %0d: %h, want %h", a, u_arbiter.mem[a],
                     expected_c(a, 1'b1));
          end
        end
      end
      $display("JOB B faulted and held at cycle %0d", cycle);
    end

    // C. Reset in the middle of a job.
    coordinated_reset();
    resets++;
    fault_expected = 1'b0;
    paint_sram();
    job_a(1'b0);
    begin
      int waited_cycles;
      waited_cycles = 0;
      while (int'(progress[MATRIX]) < 1) begin
        tick();
        waited_cycles++;
        if (waited_cycles > JOB_TIMEOUT) begin
          $fatal(1, "bpu_matrix_unit_system_tb: job C never started");
        end
      end
      repeat (rand32() % 50) begin
        tick();
      end
      if (mx_idle !== 1'b0) begin
        errors++;
        $display("bpu_matrix_unit_system_tb: job C: the matrix unit was not busy at the reset");
      end
      $display("JOB C reset at cycle %0d", cycle);
    end
    coordinated_reset();
    resets++;

    // A again, on the same hardware.
    paint_sram();
    job_a(1'b1);
    finish(8, 3 * GV_COMMANDS, 4, 1'b1, "A2");

    if (errors != 0 || model_errors != 0 || stub_errors != 0 || jobs_done != 2 || resets != 3
        || bytes_checked != 3 * (GV_C_HI - GV_C_LO) || blocked_offer_cycles != 300
        || gating_checks == 0 || (StallPct > 0 && waited[MATRIX] == 0) || waited[VECTOR] == 0) begin
      status = "FAIL";
    end else begin
      status = "PASS";
    end
    $write("RESULT bpu_matrix_unit_system_tb stall_pct=%0d mem_delay_max=%0d seed=%0d", StallPct,
           MemDelayMax, seed);
    $write(" jobs=%0d resets=%0d bytes_checked=%0d gating_checks=%0d blocked_offer_cycles=%0d",
           jobs_done, resets, bytes_checked, gating_checks, blocked_offer_cycles);
    $write(" accepted_mm=%0d accepted_mx=%0d accepted_vx=%0d", accepted[MEMORY], accepted[MATRIX],
           accepted[VECTOR]);
    $write(" waited_mm=%0d waited_mx=%0d waited_vx=%0d", waited[MEMORY], waited[MATRIX],
           waited[VECTOR]);
    $display(" model_errors=%0d stub_errors=%0d errors=%0d status=%s", model_errors, stub_errors,
             errors, status);
    if (status != "PASS") begin
      $fatal(1, "bpu_matrix_unit_system_tb: FAIL (%0d errors, %0d model errors)", errors,
             model_errors);
    end
    $finish;
  end

endmodule
