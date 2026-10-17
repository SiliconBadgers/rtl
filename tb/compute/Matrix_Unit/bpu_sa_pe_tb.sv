// Self-checking testbench for the output-stationary bpu_sa_pe: every signed
// int8 x int8 pair and every int8 x int4 pair through the accumulator and the
// capture, random traffic through the modes, the tile flags and the drain shift,
// and the flag reset.
//
// Phases
//   1. pairs   For each of the 65,536 pairs (a, b), in INT8 mode: one k-step with
//              first = 1 and a random (a0, b0), then one with last = 1 and (a, b).
//              The shadow must then hold a0*b0 + a*b (mod 2^AccW): the restart,
//              one carry-save accumulation and the capture.
//   2. int4    (Int4 = 1 only) The same in INT4-pair mode for each of the 4,096
//              (int8, int4) pairs, once in the low half of the PE (A low byte x B
//              low nibble) and once in the high half, with random values in the
//              other half: each check covers a0*w0 + a1*w1.
//   3. random  TrafficCycles cycles of random a, b, mode (50% INT4-pair with
//              Int4), first (15%), last (15%) and, when last = 0, shift (30%) with
//              random shadow inputs from below.
//              Model: first restarts the accumulator, last captures it into the
//              shadow, shift loads the shadow from below bit for bit, otherwise the
//              shadow holds.
//   4. reset   rst_n is asserted between clock edges with first = last = 1 driven:
//              first_o and last_o must drop at once and stay 0 until release.
//
// Checks every cycle: a_o, b_o, first_o, last_o are the inputs of the previous
// cycle; the shadow outputs match the model (sum + carry after a capture, the
// exact sum and carry bits after a shift). The run ends with $fatal(1, ...) on any
// mismatch, on a wrong check count or on timeout, and prints one RESULT line for
// the regression runner (tb/compute/Matrix_Unit/run_tests.sh).
//
// Parameters: AccW and Int4 (the PE under test), TrafficCycles, Seed (the default
// seed).
// Plusargs:
//   +seed=<n>       random seed (default: Seed)
//   +inject_error=1 corrupt one expected value on purpose; the run must FAIL
//
// Scheduling: inputs are driven and outputs checked on the falling clock edge; the
// design samples on the rising edge.
module bpu_sa_pe_tb;
  timeunit 1ns; timeprecision 1ps;

  parameter int AccW = 32;
  parameter bit Int4 = 1'b1;
  parameter int TrafficCycles = 20000;
  parameter int Seed = 1;

  localparam int PAIRS = 256 * 256;
  localparam int INT4_PAIRS = Int4 ? 2 * 256 * 16 : 0;  // both halves
  localparam int AW = Int4 ? 16 : 8;  // A path width
  localparam int TIMEOUT_CYCLES = 2 * (PAIRS + INT4_PAIRS) + TrafficCycles + 1000;

  logic                   clk;
  logic                   rst_n;
  logic        [  AW-1:0] a;
  logic                   mode;
  logic                   first;
  logic                   last;
  logic        [  AW-1:0] a_out;
  logic                   first_out;
  logic                   last_out;
  logic        [     7:0] b;
  logic        [     7:0] b_out;
  logic                   shift;
  logic        [AccW-1:0] shd_sum_in;
  logic        [AccW-1:0] shd_carry_in;
  logic        [AccW-1:0] shd_sum_out;
  logic        [AccW-1:0] shd_carry_out;

  // Reference model: the accumulator value, and the shadow either as a value
  // (after a capture) or as exact sum and carry bits (after a shift).
  logic        [AccW-1:0] acc_val;
  logic        [AccW-1:0] shd_val;
  logic        [AccW-1:0] shd_sum_exp;
  logic        [AccW-1:0] shd_carry_exp;
  bit                     shd_exact;
  bit                     shd_known;
  logic        [  AW-1:0] prev_a;
  logic        [     7:0] prev_b;
  logic                   prev_first;
  logic                   prev_last;

  int                     seed;
  int unsigned            rng_state;
  bit                     inject_error;
  int                     inject_arg;
  bit                     injected;
  int                     errors;
  int                     pair_checks;
  int                     int4_pair_checks;
  int                     int4_cycles;
  int                     cycle_checks;
  int                     captures;
  int                     shifts;
  int                     restarts;
  int                     reset_checks;
  string                  status;

  bpu_sa_pe #(
    .AccW(AccW),
    .Int4(Int4)
  ) u_dut (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .mode_i     (mode),
    .a_i        (a),
    .first_i    (first),
    .last_i     (last),
    .a_o        (a_out),
    .first_o    (first_out),
    .last_o     (last_out),
    .b_i        (b),
    .b_o        (b_out),
    .shift_i    (shift),
    .shd_sum_i  (shd_sum_in),
    .shd_carry_i(shd_carry_in),
    .shd_sum_o  (shd_sum_out),
    .shd_carry_o(shd_carry_out)
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
    $fatal(1, "bpu_sa_pe_tb: timeout after %0d cycles", TIMEOUT_CYCLES);
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

  function automatic logic [AccW-1:0] rand_acc();
    logic [63:0] r;
    r = {rand32(), rand32()};
    return r[AccW-1:0];
  endfunction

  // What the PE adds in one cycle, as an AccW-bit two's-complement value.
  // INT8: x[7:0] * y. INT4 pair: x[7:0] * y[3:0] + x[15:8] * y[7:4].
  function automatic logic [AccW-1:0] product(input logic [15:0] x, input logic [7:0] y,
                                              input logic int4);
    logic signed [63:0] p;
    if (int4) begin
      p = 64'($signed(x[7:0])) * 64'($signed(y[3:0]));
      p = p + 64'($signed(x[15:8])) * 64'($signed(y[7:4]));
    end else begin
      p = 64'($signed(x[7:0])) * 64'($signed(y));
    end
    return p[AccW-1:0];
  endfunction

  // Model the rising edge for the inputs driven now.
  task automatic model_edge();
    logic [AccW-1:0] p;
    p = product(16'(a), b, Int4 && mode);
    if (Int4 && mode) begin
      int4_cycles++;
    end
    if (first) begin
      acc_val = p;
      restarts++;
    end else begin
      acc_val = acc_val + p;
    end
    if (last) begin
      shd_val   = acc_val;
      shd_exact = 1'b0;
      shd_known = 1'b1;
      captures++;
    end else if (shift) begin
      shd_sum_exp   = shd_sum_in;
      shd_carry_exp = shd_carry_in;
      shd_exact     = 1'b1;
      shd_known     = 1'b1;
      shifts++;
    end
    if (inject_error && !injected && shd_known && !shd_exact && captures > 3) begin
      shd_val  = shd_val + 1'b1;
      injected = 1'b1;
    end
    prev_a     = a;
    prev_b     = b;
    prev_first = first;
    prev_last  = last;
  endtask

  // Check what the design registered at the last rising edge.
  task automatic check_outputs();
    logic [AccW-1:0] got;
    cycle_checks++;
    if (a_out !== prev_a || b_out !== prev_b || first_out !== prev_first
        || last_out !== prev_last) begin
      errors++;
      if (errors <= 10) begin
        $display("bpu_sa_pe_tb: pipeline outputs a=%h b=%h first=%b last=%b, want %h %h %b %b",
                 a_out, b_out, first_out, last_out, prev_a, prev_b, prev_first, prev_last);
      end
    end
    if (shd_known) begin
      if (shd_exact) begin
        if (shd_sum_out !== shd_sum_exp || shd_carry_out !== shd_carry_exp) begin
          errors++;
          if (errors <= 10) begin
            $display("bpu_sa_pe_tb: shadow after a shift is %h/%h, want %h/%h", shd_sum_out,
                     shd_carry_out, shd_sum_exp, shd_carry_exp);
          end
        end
      end else begin
        got = shd_sum_out + shd_carry_out;
        if (got !== shd_val) begin
          errors++;
          if (errors <= 10) begin
            $display("bpu_sa_pe_tb: shadow value %0d, want %0d", $signed(got), $signed(shd_val));
          end
        end
      end
    end
  endtask

  task automatic step();
    model_edge();
    @(negedge clk);
    check_outputs();
  endtask

  // One restart-then-capture check: (a0, b0) with first = 1, then (a1, b1) with
  // last = 1, both in mode m.
  task automatic pair_check(input logic [AW-1:0] a0, input logic [7:0] b0, input logic [AW-1:0] a1,
                            input logic [7:0] b1, input logic m);
    mode  = m;
    a     = a0;
    b     = b0;
    first = 1'b1;
    last  = 1'b0;
    step();
    a     = a1;
    b     = b1;
    first = 1'b0;
    last  = 1'b1;
    step();  // checks the shadow against the two products
  endtask

  initial begin : main
    logic [7:0] x8;
    logic [3:0] w4;

    if (!$value$plusargs("seed=%d", seed)) begin
      seed = Seed;
    end
    if (!$value$plusargs("inject_error=%d", inject_arg)) begin
      inject_arg = 0;
    end
    inject_error     = (inject_arg != 0);
    injected         = 1'b0;
    errors           = 0;
    pair_checks      = 0;
    int4_pair_checks = 0;
    int4_cycles      = 0;
    cycle_checks     = 0;
    captures         = 0;
    shifts           = 0;
    restarts         = 0;
    reset_checks     = 0;
    shd_known        = 1'b0;
    shd_exact        = 1'b0;
    acc_val          = '0;
    rng_state        = seed ^ 32'h9e37_79b9;
    if (rng_state == 0) begin
      rng_state = 1;
    end

    rst_n        = 1'b0;
    mode         = 1'b0;
    a            = '0;
    b            = '0;
    first        = 1'b0;
    last         = 1'b0;
    shift        = 1'b0;
    shd_sum_in   = '0;
    shd_carry_in = '0;
    prev_a       = '0;
    prev_b       = '0;
    prev_first   = 1'b0;
    prev_last    = 1'b0;
    repeat (2) begin
      @(negedge clk);
    end
    rst_n = 1'b1;

    // 1. every INT8 pair through restart, accumulate and capture
    for (int x = 0; x < 256; x++) begin
      for (int y = 0; y < 256; y++) begin
        pair_check(AW'(rand32()), 8'(rand32()), AW'(x), 8'(y), 1'b0);
        pair_checks++;
      end
    end

    // 2. every (int8, int4) pair in each half of the INT4-pair mode
    if (Int4) begin
      for (int half = 0; half < 2; half++) begin
        for (int x = 0; x < 256; x++) begin
          for (int y = 0; y < 16; y++) begin
            x8 = 8'(x);
            w4 = 4'(y);
            if (half == 0) begin
              pair_check(AW'(rand32()), 8'(rand32()), AW'({8'(rand32()), x8}), {4'(rand32()), w4},
                         1'b1);
            end else begin
              pair_check(AW'(rand32()), 8'(rand32()), AW'({x8, 8'(rand32())}), {w4, 4'(rand32())},
                         1'b1);
            end
            int4_pair_checks++;
          end
        end
      end
    end

    // 3. random modes, flags, data and drain shifts
    for (int c = 0; c < TrafficCycles; c++) begin
      mode         = Int4 && (rand_below(2) == 1);
      a            = AW'(rand32());
      b            = 8'(rand32());
      first        = (rand_below(100) < 15);
      last         = (rand_below(100) < 15);
      shift        = !last && (rand_below(100) < 30);
      shd_sum_in   = rand_acc();
      shd_carry_in = rand_acc();
      step();
    end
    shift = 1'b0;

    // 4. reset clears the flag outputs at once and holds them at 0
    first = 1'b1;
    last  = 1'b1;
    #2;
    rst_n = 1'b0;
    #1;
    if (first_out !== 1'b0 || last_out !== 1'b0) begin
      errors++;
      $display("bpu_sa_pe_tb: reset did not clear first_o and last_o at once");
    end
    reset_checks++;
    repeat (2) begin
      @(negedge clk);
      if (first_out !== 1'b0 || last_out !== 1'b0) begin
        errors++;
        $display("bpu_sa_pe_tb: first_o or last_o rose while reset was held");
      end
      reset_checks++;
    end
    first = 1'b0;
    last  = 1'b0;
    rst_n = 1'b1;

    if (errors != 0 || pair_checks != PAIRS || int4_pair_checks != INT4_PAIRS
        || cycle_checks != 2 * (PAIRS + INT4_PAIRS) + TrafficCycles || shifts == 0
        || captures <= PAIRS || reset_checks != 3 || (Int4 && int4_cycles == 0)) begin
      status = "FAIL";
    end else begin
      status = "PASS";
    end
    $write("RESULT bpu_sa_pe_tb accw=%0d int4=%0d seed=%0d pair_checks=%0d", AccW, Int4, seed,
           pair_checks);
    $write(" int4_pair_checks=%0d int4_cycles=%0d cycle_checks=%0d", int4_pair_checks, int4_cycles,
           cycle_checks);
    $write(" captures=%0d shifts=%0d restarts=%0d reset_checks=%0d", captures, shifts, restarts,
           reset_checks);
    $display(" errors=%0d status=%s", errors, status);
    if (status != "PASS") begin
      $fatal(1, "bpu_sa_pe_tb: FAIL (%0d errors)", errors);
    end
    $finish;
  end

endmodule
