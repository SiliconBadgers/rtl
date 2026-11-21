// Self-checking testbench for bpu_matrix_unit, the Matrix unit as the top-level
// controller sees it: version-1 records on the command-queue port, milestones, idle
// and a sticky fault, with sram_arbiter_matrix_model (the arbiter's Matrix channel and
// the SRAM behind it) on the other side. The data are the real Qwen3.5-2B tensors of
// bpu_sa_golden_vectors_pkg, checked bit for bit, so this bench also checks that the
// record decoder is wired to the wrapper field for field.
//
// Parameters: PayloadWidth (the system's queue payload, 512 or wider), Latency and
// ReadyPct (the model), FaultHoldCycles, Seed. The unit is 8 x 8, AccW 32, DataW
// 4096, BlockK 16, INT4 and block scaling on, matching the package.
// Plusargs:
//   +seed=<n>       seed for the wait-target junk and the model (default: Seed)
//   +inject_error=1 corrupt one expected value on purpose; the run must FAIL
//
// Phases
//   1. golden    every command of the package, encoded as a version-1 record by
//                bpu_matrix_record_tb_pkg, with random nonzero wait-target words that the unit
//                must ignore. They are offered back to back, as a queue with work
//                waiting does: the next record is on the port the cycle after the
//                previous one is accepted.
//   2. faults    each of these is accepted, raises fault_o and must not touch memory
//                or publish a milestone: a record with version 2, a record with
//                transpose A set (both rejected by the decoder), a well-formed record
//                with A misaligned (rejected by the wrapper) and, when PayloadWidth >
//                512, a legal record with one bit above 511 set. After each, a legal
//                record is offered for FaultHoldCycles cycles and must not be
//                accepted; then the coordinated reset (unit, model and the
//                testbench's progress counter together) clears the fault, and a
//                standalone command must run correctly.
//   3. reset     a long command is reset while it is reading; the unit must come out
//                idle, fault-free and ready, and a standalone command must then run
//                correctly (its C region is repainted first, so a missing write shows).
//
// Checks every cycle (falling edge; the design acts on the rising edge):
//   - milestone_inc_o is 00, 01 or 10, never unknown
//   - idle_o is high exactly when every accepted legal command's three milestones
//     have been counted (by the counter kept here as the command queues keep it)
//   - fault_o is high exactly from the cycle after an illegal record is accepted
//     until reset; cmd_ready_o is low while it is high, and high whenever the unit
//     is idle without a fault
//   - every request has matrix_req_transpose_o = 0 and matrix_req_element_width_o = 0,
//     and there are no requests while faulted
// Per legal command: its first milestone (inputs released) is counted before its
// third (complete); when the third is counted no write is in flight and every C
// element is right; a command that keeps its sums writes nothing. Per illegal
// command: no request, no milestone. The model checks the port protocol, reads inside
// the image and writes inside the C region. The run ends with $fatal(1, ...) on any
// error, a count mismatch or a timeout, and prints one RESULT line for the runner.
module bpu_matrix_unit_tb;
  timeunit 1ns; timeprecision 1ps;
  import bpu_sa_pkg::*;
  import bpu_sa_golden_vectors_pkg::*;
  import bpu_matrix_record_tb_pkg::*;

  parameter int PayloadWidth = 512;
  parameter int Latency = 4;
  parameter int ReadyPct = 70;
  parameter int FaultHoldCycles = 40;
  parameter int Seed = 1;

  localparam int ROWS = GV_ROWS;
  localparam int COLS = GV_COLS;
  localparam int DATA_WIDTH = 8 * GV_ROW_BYTES;
  localparam int ADDR_WIDTH = 32;
  localparam int SIZE_WIDTH = $clog2(GV_ROW_BYTES) + 1;
  localparam int MEM_BYTES = GV_MEM_ROWS * GV_ROW_BYTES;
  localparam int CMD_TIMEOUT = (2048 * (Latency + 4) + 400) * 100 / ReadyPct + 1;
  localparam bit WIDE = PayloadWidth > RECORD_W;
  localparam int FAULT_CASES = WIDE ? 4 : 3;
  // The golden list, one recovery command per fault case and one after the reset.
  localparam int COMMANDS = GV_COMMANDS + FAULT_CASES + 1;
  localparam int TIMEOUT_CYCLES = (COMMANDS + 4) * CMD_TIMEOUT
                                  + FAULT_CASES * (FaultHoldCycles + 20);
  localparam int RECOVERY_CMD = 0;  // standalone INT4 block-scaled, K = 2048
  localparam int RESET_CMD = 1;  // standalone INT8 block-scaled, K = 2048

  logic clk;
  logic rst_n;

  logic cmd_valid;
  logic cmd_ready;
  logic [PayloadWidth-1:0] cmd_payload;
  logic [1:0] milestone_inc;
  logic idle;
  logic fault;

  logic req_valid;
  logic req_ready;
  logic req_is_write;
  logic [SIZE_WIDTH-1:0] req_size;
  logic [ADDR_WIDTH-1:0] req_addr;
  logic [DATA_WIDTH-1:0] req_wdata;
  logic req_transpose;
  logic [1:0] req_element_width;
  logic rsp_valid;
  logic [DATA_WIDTH-1:0] rsp_rdata;

  logic [3:0][ADDR_WIDTH-1:0] rd_lo;
  logic [3:0][ADDR_WIDTH-1:0] rd_hi;
  logic [ADDR_WIDTH-1:0] c_lo;
  logic [ADDR_WIDTH-1:0] c_hi;
  int reads;
  int writes;
  int read_bytes;
  int write_bytes;
  int model_errors;
  int req_stalls;
  int in_flight;
  int write_in_flight;
  int completed_writes;

  // The Matrix progress counter and what the testbench has handed the unit since the
  // last reset, kept as the command queues and the controller would keep them.
  int progress;
  int legal_accepted;
  bit fault_exp;
  bit offer_legal;  // the record on the port is legal

  int cycle;
  int seed;
  int unsigned rng;
  int inject_arg;
  bit inject_error;
  int errors;
  int commands_checked;
  int c_checked;
  int kept_checked;
  int illegal_accepted;
  int decoder_faults;
  int wrapper_faults;
  int high_bit_faults;
  int blocked_cycles;  // cycles a legal record waited on a faulted unit
  int resets;
  int requests_checked;
  int idle_gap_cycles;  // cycles with the last milestones still due (idle_o low, no work)
  int writes_at_accept[COMMANDS];
  string status;

  bpu_matrix_unit #(
    .PayloadWidth(PayloadWidth),
    .Rows        (ROWS),
    .Cols        (COLS),
    .AccW        (32),
    .DataW       (DATA_WIDTH),
    .SizeW       (SIZE_WIDTH),
    .BufRows     (2),
    .Int4        (1'b1),
    .Scale       (1'b1),
    .BlockK      (GV_BLOCK_K)
  ) u_dut (
    .clk_i                     (clk),
    .rst_ni                    (rst_n),
    .cmd_valid_i               (cmd_valid),
    .cmd_ready_o               (cmd_ready),
    .cmd_payload_i             (cmd_payload),
    .milestone_inc_o           (milestone_inc),
    .idle_o                    (idle),
    .fault_o                   (fault),
    .matrix_req_valid_o        (req_valid),
    .matrix_req_ready_i        (req_ready),
    .matrix_req_is_write_o     (req_is_write),
    .matrix_req_size_bytes_o   (req_size),
    .matrix_req_addr_o         (req_addr),
    .matrix_req_wdata_o        (req_wdata),
    .matrix_req_transpose_o    (req_transpose),
    .matrix_req_element_width_o(req_element_width),
    .matrix_rsp_valid_i        (rsp_valid),
    .matrix_rsp_rdata_i        (rsp_rdata)
  );

  sram_arbiter_matrix_model #(
    .AddrW   (ADDR_WIDTH),
    .DataW   (DATA_WIDTH),
    .SizeW   (SIZE_WIDTH),
    .MemBytes(MEM_BYTES),
    .Latency (Latency),
    .ReadyPct(ReadyPct)
  ) u_sram (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .req_valid_i       (req_valid),
    .req_ready_o       (req_ready),
    .req_is_write_i    (req_is_write),
    .req_size_bytes_i  (req_size),
    .req_addr_i        (req_addr),
    .req_wdata_i       (req_wdata),
    .rsp_valid_o       (rsp_valid),
    .rsp_rdata_o       (rsp_rdata),
    .rd_lo_i           (rd_lo),
    .rd_hi_i           (rd_hi),
    .c_lo_i            (c_lo),
    .c_hi_i            (c_hi),
    .reads_o           (reads),
    .writes_o          (writes),
    .read_bytes_o      (read_bytes),
    .write_bytes_o     (write_bytes),
    .errors_o          (model_errors),
    .stalls_o          (req_stalls),
    .in_flight_o       (in_flight),
    .write_in_flight_o (write_in_flight),
    .completed_writes_o(completed_writes)
  );

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
    $fatal(1, "bpu_matrix_unit_tb: timeout after %0d cycles", TIMEOUT_CYCLES);
  end

  // The controller's view, updated on the rising edge: progress counts milestones,
  // and each accepted record either owes three milestones (legal) or raises the fault.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      progress       <= 0;
      legal_accepted <= 0;
      fault_exp      <= 1'b0;
    end else begin
      if (milestone_inc === 2'b11 || $isunknown(milestone_inc)) begin
        errors++;
        $display("bpu_matrix_unit_tb: milestone_inc_o = %b at cycle %0d", milestone_inc, cycle);
      end
      progress <= progress + int'(milestone_inc);
      if (cmd_valid === 1'b1 && cmd_ready === 1'b1) begin
        if (offer_legal) begin
          legal_accepted <= legal_accepted + 1;
        end else begin
          fault_exp <= 1'b1;
          illegal_accepted++;
        end
      end
    end
  end

  // Every-cycle checks. Everything compared here changes only on rising edges. Not at time
  // 0: clk's first assignment is a falling edge before any register is reset.
  always @(negedge clk) begin
    cycle++;
    if ($time > 0 && rst_n !== 1'bx) begin
      if (idle !== (progress == 3 * legal_accepted)) begin
        errors++;
        $display("bpu_matrix_unit_tb: idle_o = %b with %0d milestones for %0d %s at cycle %0d",
                 idle, progress, legal_accepted, "legal commands", cycle);
      end
      if (fault !== fault_exp) begin
        errors++;
        $display("bpu_matrix_unit_tb: fault_o = %b, expected %b, at cycle %0d", fault, fault_exp,
                 cycle);
      end
      if (fault === 1'b1 && cmd_ready !== 1'b0) begin
        errors++;
        $display("bpu_matrix_unit_tb: cmd_ready_o high while faulted at cycle %0d", cycle);
      end
      if (idle === 1'b1 && fault === 1'b0 && cmd_ready !== 1'b1) begin
        errors++;
        $display("bpu_matrix_unit_tb: idle without a fault but not ready at cycle %0d", cycle);
      end
      // Coverage only (a peek inside): no command running, milestones still due.
      if (rst_n === 1'b1 && idle === 1'b0 && u_dut.wrap_busy === 1'b0) begin
        idle_gap_cycles++;
      end
      if (rst_n === 1'b1 && req_valid === 1'b1) begin
        requests_checked++;
        if (req_transpose !== 1'b0 || req_element_width !== 2'b00) begin
          errors++;
          $display("bpu_matrix_unit_tb: request with transpose %b, element width %b at cycle %0d",
                   req_transpose, req_element_width, cycle);
        end
        if (fault === 1'b1) begin
          errors++;
          $display("bpu_matrix_unit_tb: request while faulted at cycle %0d", cycle);
        end
      end
    end
  end

  // xorshift32, seeded from +seed: the same stimulus on every simulator.
  function automatic int unsigned rand32();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  // Golden command n as a record, with junk wait-target words (never zero).
  function automatic logic [PayloadWidth-1:0] golden_record(input int n);
    return PayloadWidth'(matrix_record(n, 8'd1, rand32() | 32'd1, rand32() | 32'd1));
  endfunction

  task automatic tick();
    @(negedge clk);
  endtask

  // Reads anywhere in the image; writes only in the C region. Faulted phases allow
  // nothing, so any request is a model error.
  task automatic open_windows();
    for (int s = 0; s < 4; s++) begin
      rd_lo[s] = '0;
      rd_hi[s] = ADDR_WIDTH'(MEM_BYTES);
    end
    c_lo = ADDR_WIDTH'(GV_C_LO);
    c_hi = ADDR_WIDTH'(GV_C_HI);
  endtask

  task automatic close_windows();
    rd_lo = '0;
    rd_hi = '0;
    c_lo  = '0;
    c_hi  = '0;
  endtask

  // Offer one record and return on the falling edge after the rising edge that
  // accepted it. The caller may put the next record on the port at once.
  task automatic offer(input logic [PayloadWidth-1:0] p, input bit legal);
    int waited;
    cmd_payload = p;
    offer_legal = legal;
    cmd_valid   = 1'b1;
    waited      = 0;
    while (cmd_ready !== 1'b1) begin
      tick();
      waited++;
      if (waited > CMD_TIMEOUT) begin
        $fatal(1, "bpu_matrix_unit_tb: a record was never accepted");
      end
    end
    tick();
    cmd_valid = 1'b0;
  endtask

  // Check command n's C against the golden model.
  task automatic check_c(input int n);
    logic [31:0] got;
    logic [31:0] want;
    for (int e = 0; e < ROWS * COLS; e++) begin
      for (int b = 0; b < 4; b++) begin
        got[8*b+:8] = u_sram.mem[GV_CMD[n][9]+4*e+b];
      end
      want = GV_C[n][e];
      if (inject_error && commands_checked == 0 && e == 0) begin
        want = want ^ 32'h1;
      end
      c_checked++;
      if (got !== want) begin
        errors++;
        if (errors <= 10) begin
          $display("bpu_matrix_unit_tb: MISMATCH cmd %0d C[%0d][%0d] got %h want %h", n, e / COLS,
                   e % COLS, got, want);
        end
      end
    end
  endtask

  // Golden commands first .. first + count - 1, offered back to back. The second branch
  // follows the milestones: a command is complete when its third one is counted.
  task automatic run_golden(input int first, input int count);
    int base;
    base = legal_accepted;
    open_windows();
    fork
      begin : offer_records
        for (int i = 0; i < count; i++) begin
          offer(golden_record(first + i), 1'b1);
          writes_at_accept[base+i] = writes;
        end
      end
      begin : follow_milestones
        for (int i = 0; i < count; i++) begin
          int n;
          int j;
          int waited;
          int inputs_cycle;
          n      = first + i;
          j      = base + i;
          waited = 0;
          while (progress < 3 * j + 1) begin
            tick();
            waited++;
            if (waited > 2 * CMD_TIMEOUT) begin
              $fatal(1, "bpu_matrix_unit_tb: command %0d never released its inputs", n);
            end
          end
          inputs_cycle = cycle;
          while (progress < 3 * j + 3) begin
            tick();
            waited++;
            if (waited > 2 * CMD_TIMEOUT) begin
              $fatal(1, "bpu_matrix_unit_tb: command %0d never completed", n);
            end
          end
          if (inputs_cycle >= cycle) begin
            errors++;
            $display("bpu_matrix_unit_tb: command %0d: inputs released with complete", n);
          end
          if (write_in_flight != 0) begin
            errors++;
            $display("bpu_matrix_unit_tb: command %0d complete with a write in flight", n);
          end
          if (GV_CMD[n][4] == 0) begin
            kept_checked++;
            if (writes != writes_at_accept[j]) begin
              errors++;
              $display("bpu_matrix_unit_tb: command %0d kept its sums but wrote C", n);
            end
          end else begin
            check_c(n);  // +inject_error corrupts the first command's first element
          end
          commands_checked++;
          $display("CMD %0d k=%0d int4=%0d scaled=%0d clear=%0d write=%0d done at cycle %0d", n,
                   GV_CMD[n][0], GV_CMD[n][1], GV_CMD[n][2], GV_CMD[n][3], GV_CMD[n][4], cycle);
        end
      end
    join
  endtask

  // The controller's coordinated reset: unit, arbiter model and progress counter
  // together, asserted between clock edges and released on a falling edge.
  task automatic coordinated_reset();
    #2;
    rst_n = 1'b0;
    repeat (3) begin
      tick();
    end
    rst_n = 1'b1;
    tick();
    if (idle !== 1'b1 || fault !== 1'b0 || cmd_ready !== 1'b1 || req_valid !== 1'b0) begin
      errors++;
      $display("bpu_matrix_unit_tb: after reset idle %b fault %b ready %b request %b", idle, fault,
               cmd_ready, req_valid);
    end
  endtask

  // One illegal record, then a legal one that must wait, then reset and recovery.
  task automatic fault_case(input logic [PayloadWidth-1:0] bad, input string what);
    int reads0;
    int writes0;
    int progress0;
    close_windows();
    reads0    = reads;
    writes0   = writes;
    progress0 = progress;
    offer(bad, 1'b0);
    cmd_payload = golden_record(RECOVERY_CMD);
    offer_legal = 1'b1;
    cmd_valid   = 1'b1;
    repeat (FaultHoldCycles) begin
      tick();
      if (cmd_ready === 1'b0) begin
        blocked_cycles++;
      end
    end
    cmd_valid = 1'b0;
    if (reads != reads0 || writes != writes0 || progress != progress0 || fault !== 1'b1
        || idle !== 1'b1) begin
      errors++;
      $display("bpu_matrix_unit_tb: %s: %0d reads, %0d writes, %0d milestones, fault %b, idle %b",
               what, reads - reads0, writes - writes0, progress - progress0, fault, idle);
    end
    $display("FAULT %s at cycle %0d", what, cycle);
    coordinated_reset();
    run_golden(RECOVERY_CMD, 1);
  endtask

  initial begin : main
    logic [PayloadWidth-1:0] r;
    int reads_before_reset;
    if (!$value$plusargs("seed=%d", seed)) begin
      seed = Seed;
    end
    if (!$value$plusargs("inject_error=%d", inject_arg)) begin
      inject_arg = 0;
    end
    inject_error     = (inject_arg != 0);
    rng              = 32'h9E37_79B9 ^ seed;
    errors           = 0;
    commands_checked = 0;
    c_checked        = 0;
    kept_checked     = 0;
    illegal_accepted = 0;
    decoder_faults   = 0;
    wrapper_faults   = 0;
    high_bit_faults  = 0;
    blocked_cycles   = 0;
    resets           = 0;
    requests_checked = 0;
    idle_gap_cycles  = 0;
    cycle            = 0;

    rst_n            = 1'b0;
    cmd_valid        = 1'b0;
    cmd_payload      = '0;
    offer_legal      = 1'b1;
    close_windows();
    for (int r_ = 0; r_ < GV_MEM_ROWS; r_++) begin
      for (int b = 0; b < GV_ROW_BYTES; b++) begin
        u_sram.mem[r_*GV_ROW_BYTES+b] = GV_MEM[r_][8*b+:8];
      end
    end
    // Stale C regions hold a pattern no expected value has, so a missing write shows.
    for (int a = GV_C_LO; a < GV_C_HI; a++) begin
      u_sram.mem[a] = 8'hA5;
    end
    repeat (2) begin
      tick();
    end
    rst_n = 1'b1;
    tick();

    // 1. The golden list, back to back.
    run_golden(0, GV_COMMANDS);

    // 2. Faults.
    r = golden_record(RECOVERY_CMD);
    r[VERSION_LSB+:8] = 8'd2;
    fault_case(r, "version 2");
    decoder_faults++;
    r = golden_record(RECOVERY_CMD);
    r[TRANSPOSE_A_BIT] = 1'b1;
    fault_case(r, "transpose A");
    decoder_faults++;
    r = golden_record(RECOVERY_CMD);
    r[A_ADDRESS_LSB+:32] = r[A_ADDRESS_LSB+:32] + 32'd1;
    fault_case(r, "A misaligned");
    wrapper_faults++;
    if (WIDE) begin
      r = golden_record(RECOVERY_CMD);
      r[RECORD_W+int'(rand32()%(PayloadWidth-RECORD_W))] = 1'b1;
      fault_case(r, "payload bit above 511");
      high_bit_faults++;
    end

    // 3. Reset while a long command is reading, then a clean run.
    open_windows();
    reads_before_reset = reads;
    offer(golden_record(RESET_CMD), 1'b1);
    repeat (200 + rand32() % 200) begin
      tick();
    end
    if (progress != 3 * (legal_accepted - 1) || reads == reads_before_reset) begin
      errors++;
      $display("bpu_matrix_unit_tb: the command to reset was not running");
    end
    coordinated_reset();
    resets++;
    for (int a = GV_C_LO; a < GV_C_HI; a++) begin
      u_sram.mem[a] = 8'hA5;
    end
    run_golden(RECOVERY_CMD, 1);

    repeat (4) begin
      tick();
    end
    if (errors != 0 || model_errors != 0 || commands_checked != COMMANDS
        || c_checked != (COMMANDS - 1) * ROWS * COLS || kept_checked != 1
        || illegal_accepted != FAULT_CASES || decoder_faults != 2 || wrapper_faults != 1
        || high_bit_faults != (WIDE ? 1 : 0) || blocked_cycles != FAULT_CASES * FaultHoldCycles
        || resets != 1 || requests_checked == 0 || idle_gap_cycles < COMMANDS
        || (ReadyPct < 100 && req_stalls == 0)) begin
      status = "FAIL";
    end else begin
      status = "PASS";
    end
    $write("RESULT bpu_matrix_unit_tb payload_width=%0d latency=%0d ready_pct=%0d seed=%0d",
           PayloadWidth, Latency, ReadyPct, seed);
    $write(" commands=%0d c_checked=%0d kept=%0d illegal=%0d decoder_faults=%0d", commands_checked,
           c_checked, kept_checked, illegal_accepted, decoder_faults);
    $write(" wrapper_faults=%0d high_bit_faults=%0d blocked_cycles=%0d resets=%0d", wrapper_faults,
           high_bit_faults, blocked_cycles, resets);
    $write(" requests_checked=%0d idle_gaps=%0d reads=%0d writes=%0d", requests_checked,
           idle_gap_cycles, reads, writes);
    $display(" req_stalls=%0d model_errors=%0d errors=%0d status=%s", req_stalls, model_errors,
             errors, status);
    if (status != "PASS") begin
      $fatal(1, "bpu_matrix_unit_tb: FAIL (%0d errors, %0d model errors)", errors, model_errors);
    end
    $finish;
  end

endmodule
