// Self-checking testbench for bpu_sa_pe: every signed int8 x int8 pair through
// both A paths, plus the swap_o reset.
//
// For each pair (a, b), with random incoming sum_i and carry_i:
//   shadow path   a_shadow_q = a and a_active_q = ~a; swap_i = 1, so the PE must
//                 use the shadow value (and copy it to the active register).
//   active path   a_active_q = a and a_shadow_q = ~a; swap_i = 0, so the PE must
//                 use the active value.
// ~a differs from a in every bit, so a PE that read the wrong register fails.
// Each check compares sum_o + carry_o with sum_i + carry_i + a * b (mod 2^AccW),
// and checks b_o, swap_o and load_a_o (the shadow chain).
//
// Plusargs:
//   +seed=<n>       seed for the random sum_i / carry_i (default: Seed)
//   +inject_error=1 corrupt one expected value on purpose; the run must FAIL
//
// The run ends with $fatal(1, ...) on any mismatch, on a wrong check count or on
// timeout, and prints one RESULT line for the regression runner
// (tb/compute/Matrix_Unit/run_tests.sh).
//
// Scheduling: inputs are driven and outputs checked on the falling clock edge;
// the design samples on the rising edge.
module bpu_sa_pe_tb;
  timeunit 1ns; timeprecision 1ps;

  parameter int AccW = 32;
  parameter int Seed = 1;

  // Waiver: parameter-name-style, these localparams only. Coding standard §1 names
  // fixed constants in ALL_CAPS; Verible's default ruleset accepts only CamelCase
  // localparams. Remove once the repository lint config allows ALL_CAPS localparams.
  // verilog_lint: waive-start parameter-name-style
  localparam int PAIRS = 256 * 256;
  localparam int CYCLES_PER_PAIR = 5;
  localparam int TIMEOUT_CYCLES = CYCLES_PER_PAIR * PAIRS + 1000;
  // verilog_lint: waive-stop parameter-name-style

  logic                   clk;
  logic                   rst_n;
  logic                   load;
  logic        [     7:0] load_a;
  logic        [     7:0] load_a_out;
  logic        [     7:0] b;
  logic                   swap;
  logic        [     7:0] b_out;
  logic                   swap_out;
  logic        [AccW-1:0] sum_in;
  logic        [AccW-1:0] carry_in;
  logic        [AccW-1:0] sum_out;
  logic        [AccW-1:0] carry_out;

  int                     seed;
  int unsigned            rng_state;
  bit                     inject_error;
  int                     inject_arg;
  bit                     injected;
  int                     errors;
  int                     shadow_checks;
  int                     active_checks;
  int                     reset_checks;
  string                  status;

  bpu_sa_pe #(
    .AccW(AccW)
  ) u_dut (
    .clk_i   (clk),
    .rst_ni  (rst_n),
    .mode_i  (1'b0),
    .load_i  (load),
    .load_a_i(load_a),
    .load_a_o(load_a_out),
    .b_i     (b),
    .swap_i  (swap),
    .b_o     (b_out),
    .swap_o  (swap_out),
    .sum_i   (sum_in),
    .carry_i (carry_in),
    .sum_o   (sum_out),
    .carry_o (carry_out)
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

  // xorshift32, seeded from +seed: the same values for a given seed on every simulator.
  function automatic int unsigned rand32();
    rng_state = rng_state ^ (rng_state << 13);
    rng_state = rng_state ^ (rng_state >> 17);
    rng_state = rng_state ^ (rng_state << 5);
    return rng_state;
  endfunction

  // A random AccW-bit value (AccW up to 64).
  function automatic logic [AccW-1:0] rand_acc();
    return AccW'({rand32(), rand32()});
  endfunction

  // Drive one cycle's inputs at a falling edge and wait for the next falling edge;
  // the rising edge in between applies them.
  task automatic cycle(input bit ld, input logic [7:0] ld_a, input bit sw, input logic [7:0] bv,
                       input logic [AccW-1:0] s, input logic [AccW-1:0] c);
    load     = ld;
    load_a   = ld_a;
    swap     = sw;
    b        = bv;
    sum_in   = s;
    carry_in = c;
    @(negedge clk);
  endtask

  // Compare the outputs registered at the last rising edge.
  task automatic check(input int ai, input int bi, input logic [AccW-1:0] s,
                       input logic [AccW-1:0] c, input bit sw, input logic [7:0] shadow,
                       input string path);
    logic [AccW-1:0] want;
    want = s + c + AccW'(ai * bi);
    if (inject_error && !injected) begin
      want     = want + 1'b1;
      injected = 1'b1;
    end
    if (sum_out + carry_out !== want || b_out !== 8'(bi) || swap_out !== sw
        || load_a_out !== shadow) begin
      errors++;
      if (errors <= 10) begin
        $display("bpu_sa_pe_tb: MISMATCH %s path a=%0d b=%0d: sum+carry=%h want %h", path, ai, bi,
                 sum_out + carry_out, want);
      end
    end
  endtask

  initial begin : main
    logic [AccW-1:0] s;
    logic [AccW-1:0] c;
    logic [     7:0] a;
    logic [     7:0] na;

    if (!$value$plusargs("seed=%d", seed)) begin
      seed = Seed;
    end
    if (!$value$plusargs("inject_error=%d", inject_arg)) begin
      inject_arg = 0;
    end
    inject_error  = (inject_arg != 0);
    injected      = 1'b0;
    errors        = 0;
    shadow_checks = 0;
    active_checks = 0;
    reset_checks  = 0;
    rng_state     = seed ^ 32'h9e37_79b9;
    if (rng_state == 0) begin
      rng_state = 1;
    end

    rst_n    = 1'b0;
    load     = 1'b0;
    load_a   = '0;
    swap     = 1'b0;
    b        = '0;
    sum_in   = '0;
    carry_in = '0;
    repeat (2) begin
      @(negedge clk);
    end
    rst_n = 1'b1;

    for (int ai = -128; ai < 128; ai++) begin
      a  = 8'(ai);
      na = ~a;
      for (int bi = -128; bi < 128; bi++) begin
        // Shadow path: shadow = a, active = ~a, then switch.
        cycle(1'b1, na, 1'b0, '0, '0, '0);  // shadow <- ~a
        cycle(1'b1, a, 1'b1, '0, '0, '0);  // active <- ~a, shadow <- a
        s = rand_acc();
        c = rand_acc();
        cycle(1'b0, '0, 1'b1, 8'(bi), s, c);  // must use the shadow value a
        check(ai, bi, s, c, 1'b1, a, "shadow");
        shadow_checks++;

        // Active path: active = a (from the switch above), shadow = ~a, no switch.
        cycle(1'b1, na, 1'b0, '0, '0, '0);  // shadow <- ~a
        s = rand_acc();
        c = rand_acc();
        cycle(1'b0, '0, 1'b0, 8'(bi), s, c);  // must use the active value a
        check(ai, bi, s, c, 1'b0, na, "active");
        active_checks++;
      end
    end

    // Reset: swap_o clears as soon as rst_ni falls and stays clear after release.
    cycle(1'b0, '0, 1'b1, '0, '0, '0);
    if (swap_out !== 1'b1) begin
      errors++;
      $display("bpu_sa_pe_tb: swap_o did not follow swap_i before the reset check");
    end
    #2 rst_n = 1'b0;
    #1;
    if (swap_out !== 1'b0) begin
      errors++;
      $display("bpu_sa_pe_tb: swap_o did not clear asynchronously on reset");
    end
    reset_checks++;
    @(negedge clk);
    rst_n = 1'b1;
    cycle(1'b0, '0, 1'b0, '0, '0, '0);
    if (swap_out !== 1'b0) begin
      errors++;
      $display("bpu_sa_pe_tb: swap_o set after reset with swap_i = 0");
    end
    reset_checks++;

    if (errors != 0 || shadow_checks != PAIRS || active_checks != PAIRS || reset_checks != 2) begin
      status = "FAIL";
    end else begin
      status = "PASS";
    end
    $write("RESULT bpu_sa_pe_tb accw=%0d seed=%0d", AccW, seed);
    $write(" shadow_path_checks=%0d active_path_checks=%0d", shadow_checks, active_checks);
    $display(" reset_checks=%0d errors=%0d status=%s", reset_checks, errors, status);
    if (status != "PASS") begin
      $fatal(1, "bpu_sa_pe_tb: FAIL (%0d errors)", errors);
    end
    $finish;
  end

endmodule
