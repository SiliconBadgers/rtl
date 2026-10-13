// Self-checking testbench for bpu_sa_array: random A tiles and B columns against a
// reference model, a reset in the middle of active work, and the int4 mode error.
//
// One array configuration per run; the regression runner
// (tb/compute/Matrix_Unit/run_tests.sh) runs several shapes and seeds.
//
// Parameters: Rows, Cols, AccW (the array under test), TrafficCycles (cycles per
// traffic phase), Seed (the default seed), and ResetWaitCycles (bounded additional
// attempts to reach the active-reset scenario).
// Plusargs:
//   +seed=<n>       random seed (default: Seed)
//   +inject_error=1 corrupt one expected value on purpose; the run must FAIL
//
// Phases
//   1. traffic  TrafficCycles cycles of random A rows (offered on 60% of free
//               cycles) and B columns (55%): gaps, stalled A rows, loads that
//               overlap streaming, and tile switches. The A producer is legal: once
//               it raises a_valid, a_valid and the row stay unchanged until a cycle
//               with a_valid && a_ready.
//   2. reset    rst_n is asserted between clock edges while A rows are loading and C
//               columns are in flight, held for 3 cycles and released on a falling
//               edge. Expected: c_valid_o and a_full_o drop at once, every in-flight
//               column is cancelled, and a_ready_o = 1 after release.
//   3. traffic  A fresh tile is loaded and traffic resumes. Every output must again
//               match the model, so no pre-reset column or tile leaks through.
//   4. drain    The remaining columns come out; then mode_i = 1 must raise
//               err_mode_o.
//
// Checks: every C column against the model, in order and exactly LATENCY_CYCLES
// after its B column; no C column when none is expected; a_full_o against the
// model; b_ready_o = 1; err_mode_o = mode_i; and AStallStable_A, an independent
// monitor that a stalled A row keeps a_valid and the row stable. The run ends with
// $fatal(1, ...) on any error, on a column-count mismatch or on timeout, and prints
// one RESULT line for the runner.
//
// Scheduling: stimulus is driven and outputs are checked on the falling clock edge;
// the design samples on the rising edge.
module bpu_sa_array_tb;
  timeunit 1ns; timeprecision 1ps;

  parameter int Rows = 8;
  parameter int Cols = 8;
  parameter int AccW = 32;
  parameter int TrafficCycles = 2000;
  parameter int Seed = 1;
  parameter int ResetWaitCycles = 1000;

  localparam int LATENCY_CYCLES = Rows + Cols + 1;
  localparam int QUEUE_DEPTH = LATENCY_CYCLES + 8;  // expected columns in flight
  localparam int TIMEOUT_CYCLES = 3 * TrafficCycles + 20 * LATENCY_CYCLES + 2000;

  logic                        clk;
  logic                        rst_n;
  logic                        mode;
  logic                        err_mode;
  logic                        a_valid;
  logic                        a_ready;
  logic                        a_full;
  logic        [   Cols*8-1:0] a_row;
  logic                        b_valid;
  logic                        b_ready;
  logic        [   Cols*8-1:0] b_col;
  logic                        c_valid;
  logic        [Rows*AccW-1:0] c_col;

  // Reference model.
  int                          next_tile           [       Rows] [Cols];
  int                          active_tile         [       Rows] [Cols];
  longint                      expect_val          [QUEUE_DEPTH] [Rows];
  int                          expect_cycle        [QUEUE_DEPTH];
  int                          head;
  int                          tail;
  int                          rows_loaded;
  bit                          tile_in_use;
  bit                          a_hold;
  int                          cycle;

  // Run control and statistics.
  int                          seed;
  int unsigned                 rng_state;
  bit                          inject_error;
  int                          inject_arg;
  bit                          injected;
  int                          errors;
  int                          columns_sent;
  int                          columns_checked;
  int                          cancelled;
  int                          rows_accepted;
  int                          a_stalls;
  int                          switches;
  int                          resets;
  int                          active_resets;
  int                          partial_load_resets;
  int                          mode_checks;
  string                       status;

  // Stall-stability monitor state.
  bit                          prev_stall;
  logic        [   Cols*8-1:0] prev_row;

  bpu_sa_array #(
    .Rows(Rows),
    .Cols(Cols),
    .AccW(AccW)
  ) u_dut (
    .clk_i     (clk),
    .rst_ni    (rst_n),
    .mode_i    (mode),
    .err_mode_o(err_mode),
    .a_valid_i (a_valid),
    .a_ready_o (a_ready),
    .a_row_i   (a_row),
    .a_full_o  (a_full),
    .b_valid_i (b_valid),
    .b_ready_o (b_ready),
    .b_col_i   (b_col),
    .c_valid_o (c_valid),
    .c_col_o   (c_col)
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
    $fatal(1, "bpu_sa_array_tb: timeout after %0d cycles", TIMEOUT_CYCLES);
  end

  // A stalled A row (valid high, ready low at a rising edge) must still be offered,
  // unchanged, at the next rising edge. Independent of the stimulus generator.
  always @(posedge clk) begin : a_stall_monitor
    if (!rst_n) begin
      prev_stall <= 1'b0;
    end else begin
      if (prev_stall) begin
        AStallStable_A :
        assert (a_valid === 1'b1 && a_row === prev_row)
        else begin
          errors++;
          $display("bpu_sa_array_tb: stalled A row was withdrawn or changed");
        end
      end
      prev_stall <= a_valid && !a_ready;
      prev_row   <= a_row;
    end
  end

  // xorshift32, seeded from +seed: the same stimulus for a given seed on every
  // simulator, so a failing seed reproduces anywhere.
  function automatic int unsigned rand32();
    rng_state = rng_state ^ (rng_state << 13);
    rng_state = rng_state ^ (rng_state >> 17);
    rng_state = rng_state ^ (rng_state << 5);
    return rng_state;
  endfunction

  function automatic int rand_below(input int n);
    return int'(rand32() % n);
  endfunction

  // A random int8, with each extreme (-128, 127) chosen 5% of the time.
  function automatic int rand_int8();
    int u;
    u = rand_below(20);
    if (u == 0) begin
      return -128;
    end
    if (u == 1) begin
      return 127;
    end
    return rand_below(256) - 128;
  endfunction

  task automatic new_tile();
    for (int i = 0; i < Rows; i++) begin
      for (int k = 0; k < Cols; k++) begin
        next_tile[i][k] = rand_int8();
      end
    end
  endtask

  // Check the outputs the design registered at the last rising edge.
  task automatic check_outputs();
    logic [AccW-1:0] want;
    int              slot;
    if (c_valid === 1'b1) begin
      if (head == tail) begin
        errors++;
        $display("bpu_sa_array_tb: unexpected C column at cycle %0d", cycle);
      end else begin
        slot = head % QUEUE_DEPTH;
        if (cycle - expect_cycle[slot] != LATENCY_CYCLES) begin
          errors++;
          $display("bpu_sa_array_tb: column %0d came out after %0d cycles, expected %0d",
                   columns_checked, cycle - expect_cycle[slot], LATENCY_CYCLES);
        end
        for (int i = 0; i < Rows; i++) begin
          want = expect_val[slot][i][AccW-1:0];
          if (c_col[i*AccW+:AccW] !== want) begin
            errors++;
            if (errors <= 10) begin
              $display("bpu_sa_array_tb: MISMATCH column %0d row %0d: got %0d want %0d",
                       columns_checked, i, $signed(c_col[i*AccW+:AccW]), $signed(want));
            end
          end
        end
        head++;
        columns_checked++;
      end
    end else if (c_valid !== 1'b0) begin
      errors++;
      $display("bpu_sa_array_tb: c_valid_o is unknown at cycle %0d", cycle);
    end
    if (a_full !== (rows_loaded == Rows)) begin
      errors++;
      $display("bpu_sa_array_tb: a_full_o = %b, model has %0d of %0d rows", a_full, rows_loaded,
               Rows);
    end
    if (b_ready !== 1'b1) begin
      errors++;
      $display("bpu_sa_array_tb: b_ready_o is not 1");
    end
    if (err_mode !== mode) begin
      errors++;
      $display("bpu_sa_array_tb: err_mode_o does not follow mode_i");
    end
  endtask

  // Choose the stimulus for the coming rising edge and model what that edge does.
  task automatic drive_and_model(input bit allow_new);
    int     b_vals[Cols];
    int     slot;
    longint s;

    // A channel: a stalled row stays offered, unchanged, until it is accepted.
    if (!a_hold) begin
      a_valid = allow_new && (rows_loaded < Rows) && (rand_below(100) < 60);
      if (a_valid) begin
        for (int k = 0; k < Cols; k++) begin
          a_row[8*k+:8] = 8'(next_tile[Rows-1-rows_loaded][k]);
        end
      end
    end

    // B channel: only once a tile is in use or a full tile is waiting to switch in.
    b_valid = allow_new && (tile_in_use || rows_loaded == Rows) && (rand_below(100) < 55);
    for (int k = 0; k < Cols; k++) begin
      b_vals[k]     = rand_int8();
      b_col[8*k+:8] = 8'(b_vals[k]);
    end

    // a_ready depends only on registers, so its value now is what the edge samples.
    a_hold = a_valid && !a_ready;
    if (a_hold) begin
      a_stalls++;
    end
    if (b_valid && rows_loaded == Rows) begin
      for (int i = 0; i < Rows; i++) begin
        for (int k = 0; k < Cols; k++) begin
          active_tile[i][k] = next_tile[i][k];
        end
      end
      rows_loaded = 0;
      tile_in_use = 1'b1;
      switches++;
      new_tile();
    end else if (a_valid && a_ready) begin
      rows_loaded++;
      rows_accepted++;
    end

    if (b_valid) begin
      slot = tail % QUEUE_DEPTH;
      for (int i = 0; i < Rows; i++) begin
        s = 0;
        for (int k = 0; k < Cols; k++) begin
          s += longint'(active_tile[i][k]) * longint'(b_vals[k]);
        end
        expect_val[slot][i] = s;
      end
      if (inject_error && !injected) begin
        expect_val[slot][0] = expect_val[slot][0] + 1;
        injected            = 1'b1;
      end
      expect_cycle[slot] = cycle;
      tail++;
      columns_sent++;
    end
  endtask

  task automatic step(input bit allow_new);
    @(negedge clk);
    cycle++;
    check_outputs();
    drive_and_model(allow_new);
  endtask

  // Assert reset while rows are loading and columns are in flight; check that it
  // cancels all accepted work.
  task automatic reset_mid_work();
    int tries;
    int in_flight;

    tries = 0;
    while (!((tail - head) > 0 && (Rows == 1 || (rows_loaded > 0 && rows_loaded < Rows)))
           && tries < ResetWaitCycles) begin
      step(1'b1);
      tries++;
    end

    if (!((tail - head) > 0 && (Rows == 1 || (rows_loaded > 0 && rows_loaded < Rows)))) begin
      $fatal(1, "active-reset precondition not reached: in_flight=%0d rows_loaded=%0d tries=%0d",
             tail - head, rows_loaded, tries);
    end

    // drive_and_model accounts for the next rising-edge transfer. Let that
    // transfer occur before asserting reset so the queued work was accepted.
    @(posedge clk);
    #2;  // between clock edges: an asynchronous assertion
    in_flight = tail - head;
    rst_n     = 1'b0;
    a_valid   = 1'b0;
    b_valid   = 1'b0;
    #1;
    if (c_valid !== 1'b0 || a_full !== 1'b0) begin
      errors++;
      $display("bpu_sa_array_tb: reset did not clear c_valid_o and a_full_o at once");
    end
    resets++;
    active_resets++;
    if (Rows > 1 && rows_loaded > 0 && rows_loaded < Rows) begin
      partial_load_resets++;
    end
    cancelled += in_flight;

    // Model: reset cancels every accepted column, row and tile.
    head        = tail;
    rows_loaded = 0;
    tile_in_use = 1'b0;
    a_hold      = 1'b0;
    new_tile();

    repeat (3) begin
      @(negedge clk);
      cycle++;
      if (c_valid !== 1'b0) begin
        errors++;
        $display("bpu_sa_array_tb: c_valid_o rose while reset was held");
      end
    end
    rst_n = 1'b1;  // released on a falling edge, half a cycle before the next rising edge
    #1;
    if (a_ready !== 1'b1 || a_full !== 1'b0 || c_valid !== 1'b0) begin
      errors++;
      $display("bpu_sa_array_tb: unexpected state after reset release");
    end
  endtask

  initial begin : main
    if (!$value$plusargs("seed=%d", seed)) begin
      seed = Seed;
    end
    if (!$value$plusargs("inject_error=%d", inject_arg)) begin
      inject_arg = 0;
    end
    inject_error        = (inject_arg != 0);
    injected            = 1'b0;
    errors              = 0;
    columns_sent        = 0;
    columns_checked     = 0;
    cancelled           = 0;
    rows_accepted       = 0;
    a_stalls            = 0;
    switches            = 0;
    resets              = 0;
    active_resets       = 0;
    partial_load_resets = 0;
    mode_checks         = 0;
    head                = 0;
    tail                = 0;
    rows_loaded         = 0;
    tile_in_use         = 1'b0;
    a_hold              = 1'b0;
    cycle               = 0;
    rng_state           = seed ^ 32'h9e37_79b9;
    if (rng_state == 0) begin
      rng_state = 1;
    end
    new_tile();

    rst_n   = 1'b0;
    mode    = 1'b0;
    a_valid = 1'b0;
    a_row   = '0;
    b_valid = 1'b0;
    b_col   = '0;
    repeat (2) begin
      @(negedge clk);
    end
    rst_n = 1'b1;

    // 1. traffic
    repeat (TrafficCycles) begin
      step(1'b1);
    end
    // 2. reset in the middle of active work
    reset_mid_work();
    // 3. traffic after reset
    repeat (TrafficCycles) begin
      step(1'b1);
    end
    // 4. drain, then the int4 mode error
    repeat (LATENCY_CYCLES + 2) begin
      step(1'b0);
    end
    if (head != tail) begin
      errors++;
      $display("bpu_sa_array_tb: %0d columns never came out", tail - head);
    end
    @(negedge clk);
    mode = 1'b1;
    #1;
    if (err_mode !== 1'b1) begin
      errors++;
      $display("bpu_sa_array_tb: err_mode_o did not rise with mode_i = 1");
    end
    mode_checks++;
    mode = 1'b0;

    if (errors != 0 || columns_checked != columns_sent - cancelled || columns_checked == 0
        || switches < 2 || resets != 1 || active_resets != 1
        || (Rows > 1 && partial_load_resets != 1) || mode_checks != 1) begin
      status = "FAIL";
    end else begin
      status = "PASS";
    end
    $write("RESULT bpu_sa_array_tb rows=%0d cols=%0d accw=%0d seed=%0d", Rows, Cols, AccW, seed);
    $write(" cycles=%0d columns_sent=%0d columns_checked=%0d cancelled=%0d", cycle, columns_sent,
           columns_checked, cancelled);
    $write(" rows_accepted=%0d a_stalls=%0d switches=%0d resets=%0d", rows_accepted, a_stalls,
           switches, resets);
    $write(" active_resets=%0d partial_load_resets=%0d", active_resets, partial_load_resets);
    $display(" errors=%0d status=%s", errors, status);
    if (status != "PASS") begin
      $fatal(1, "bpu_sa_array_tb: FAIL (%0d errors)", errors);
    end
    $finish;
  end

endmodule
