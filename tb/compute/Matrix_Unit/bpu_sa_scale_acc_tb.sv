// Self-checking unit testbench for bpu_sa_scale_acc, the block-scaling stage: every
// output bit against an independent IEEE binary32 reference, including the cases
// the end-to-end wrapper test keeps away from (signed zeros, subnormals, overflow to
// infinity, NaN, and the integer-input extremes), plus pipeline timing and reset.
//
// One configuration per run; the regression runner
// (tb/compute/Matrix_Unit/run_tests.sh) runs several shapes, widths and seeds.
//
// Parameters: Rows, Cols, AccW (the stage under test), Tiles (random tiles per
// random phase) and Seed (the default seed).
// Plusargs:
//   +seed=<n>       random seed (default: Seed)
//   +inject_error=1 corrupt one expected value on purpose; the run must FAIL
//
// Stimulus model: a tile is G blocks (1 .. MAX_BLOCKS). For each block every row
// enters once, in random order, with in_first_i on block 0 and in_emit_i on the
// last block; the last row entered in the last block carries in_last_i. Each row
// brings Cols integer block sums, its activation scale sA and the block's weight
// scales sB (bf16). The same row never re-enters within MIN_SPACING cycles, which
// is the stage's input contract (RowReuseSpacing_A); idle cycles carry random
// payload with in_valid_i = 0, which must be ignored.
//
// Phases
//   1. directed  Boundary tiles, all lanes alike: zero sums and zero scales; signed
//                zeros (-0 products must sum to +0); the largest and smallest
//                block sums; exact cancellation across blocks; overflow of the
//                scale product to infinity; infinity minus infinity (NaN); a NaN
//                scale and 0 * infinity; underflow to zero and subnormal results.
//   2. random    Tiles random tiles: sums are 10% extremes (largest, smallest,
//                +-1, 0), 40% small and 50% full range; scales are 15% special
//                values (zeros, subnormal, largest finite, infinities, NaN) and
//                otherwise normal numbers 2^-20 .. 2^21 with 10% negative. Gaps
//                of 0 to 2 cycles; no gaps in every fourth tile (one row per cycle).
//   3. reset     Rows of a tile are in flight when rst_n is asserted between clock
//                edges: out_valid_o must drop at once, stay low while reset is held,
//                and none of the cancelled rows may come out after release. A new
//                tile then runs correctly from +0.0 even though the accumulators
//                still hold old values.
//   4. random    Tiles / 2 more random tiles after the reset.
//
// Checks: every output lane bit for bit against the reference (NaN results are the
// canonical quiet NaN 7fc00000, as the FP32 units produce); outputs exactly
// LATENCY_CYCLES after their input, in order, with out_last_o passed through; no
// output for non-final blocks or idle cycles; out_valid_o never X or Z out of
// reset (OutValidKnown_A). The run fails unless the results include NaN, an
// infinity, a zero, a subnormal and a negative number, so the boundary cases were
// really reached. It ends with $fatal(1, ...) on any error, on a count mismatch or
// on timeout, and prints one RESULT line for the runner.
//
// Reference: each binary32 operation is computed in double precision, where it is
// exact for these operands, and rounded once to binary32 (round to nearest even,
// with subnormals, overflow to infinity and NaN) by real_to_f32. Double rounding
// cannot occur because the double results are exact or, for additions, double has
// 53 >= 2 * 24 + 2 significand bits.
//
// Not covered here: backpressure (the stage has none; bpu_sa_sram_wrapper reserves
// output space, and bpu_sa_sram_wrapper_tb tests that), and a deliberate violation
// of the row-spacing contract, which RowReuseSpacing_A reports inside the stage.
// This is a two-state-style test: it drives no X values into the stage.
//
// Scheduling: stimulus is driven and outputs are checked on the falling clock edge;
// the design samples on the rising edge.
module bpu_sa_scale_acc_tb;
  timeunit 1ns; timeprecision 1ps;

  parameter int Rows = 8;
  parameter int Cols = 8;
  parameter int AccW = 32;
  parameter int Tiles = 120;
  parameter int Seed = 1;

  localparam int ROW_IDX_WIDTH = $clog2((Rows > 1) ? Rows : 2);
  localparam int LATENCY_CYCLES = 8;  // in_valid_i to out_valid_o, documented
  localparam int MIN_SPACING = 8;  // cycles between two entries of one row
  localparam int MAX_BLOCKS = 6;
  localparam int QUEUE_DEPTH = 64;  // expected rows in flight (at most LATENCY_CYCLES)
  // Largest and smallest block sum: the conversion range, or AccW bits if fewer.
  localparam longint ISUM_MAX = (AccW >= 25) ? 64'sd16777215 : (64'sd1 <<< (AccW - 1)) - 1;
  localparam longint ISUM_MIN = -ISUM_MAX - 1;
  localparam logic [31:0] F32_QNAN = 32'h7fc0_0000;
  localparam int NUM_DIRECTED = 14;
  localparam int TIMEOUT_CYCLES = (2 * Tiles + NUM_DIRECTED + 10) * MAX_BLOCKS
      * (Rows * 3 + MIN_SPACING + 4) + 2000;

  logic clk;
  logic rst_n;
  logic in_valid;
  logic [Cols*AccW-1:0] in_row;
  logic [ROW_IDX_WIDTH-1:0] in_idx;
  logic in_first;
  logic in_emit;
  logic in_last;
  logic [15:0] in_sa;
  logic [Cols*16-1:0] in_sb;
  logic out_valid;
  logic [Cols*32-1:0] out_row;
  logic out_last;

  // Reference model: accumulators, and the expected rows still in the pipeline.
  logic [31:0] acc_ref[Rows][Cols];
  logic [31:0] exp_row[QUEUE_DEPTH][Cols];
  logic exp_last[QUEUE_DEPTH];
  int exp_cycle[QUEUE_DEPTH];
  int head;
  int tail;
  int last_entry[Rows];  // cycle each row last entered

  // Run control and statistics.
  int cycle;
  int seed;
  int unsigned rng_state;
  bit inject_error;
  int inject_arg;
  bit injected;
  int errors;
  int rows_entered;
  int rows_checked;
  int lanes_checked;
  int tiles_run;
  int cancelled;
  int resets;
  int nan_results;
  int inf_results;
  int zero_results;
  int subnormal_results;
  int negative_results;
  string status;

  bpu_sa_scale_acc #(
    .Rows(Rows),
    .Cols(Cols),
    .AccW(AccW)
  ) u_dut (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .in_valid_i (in_valid),
    .in_row_i   (in_row),
    .in_idx_i   (in_idx),
    .in_first_i (in_first),
    .in_emit_i  (in_emit),
    .in_last_i  (in_last),
    .in_sa_i    (in_sa),
    .in_sb_i    (in_sb),
    .out_valid_o(out_valid),
    .out_row_o  (out_row),
    .out_last_o (out_last)
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
    $fatal(1, "bpu_sa_scale_acc_tb: timeout after %0d cycles", TIMEOUT_CYCLES);
  end

  // out_valid_o must be 0 or 1 whenever the stage is out of reset.
  always @(negedge clk) begin : out_valid_monitor
    if (rst_n === 1'b1) begin
      OutValidKnown_A :
      assert (!$isunknown(out_valid))
      else begin
        errors++;
        $display("bpu_sa_scale_acc_tb: out_valid_o is X or Z at cycle %0d", cycle);
      end
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

  // A random block sum: 10% extremes, 40% small, 50% anywhere in range.
  function automatic longint rand_isum();
    int u;
    u = rand_below(20);
    if (u == 0) begin
      return ISUM_MAX;
    end
    if (u == 1) begin
      return ISUM_MIN;
    end
    if (u == 2) begin
      return (rand_below(2) == 1) ? 64'sd1 : -64'sd1;
    end
    if (u == 3) begin
      return 0;
    end
    if (u < 12) begin
      return longint'(rand_below(2049)) - 1024;
    end
    return ISUM_MIN + longint'({rand32(), rand32()} % 64'(ISUM_MAX - ISUM_MIN + 1));
  endfunction

  // A random bf16 scale: 15% special values, otherwise a normal number with an
  // exponent from 2^-20 to 2^21 and 10% negative.
  function automatic logic [15:0] rand_scale();
    logic [15:0] specials[10];
    specials = '{
      16'h0000,  // +0
      16'h8000,  // -0
      16'h0001,  // smallest subnormal
      16'h0080,  // smallest normal
      16'h7f7f,  // largest finite
      16'hff7f,  // most negative finite
      16'h7f80,  // +inf
      16'hff80,  // -inf
      16'h7fc0,  // quiet NaN
      16'h3f80  // 1.0
    };
    if (rand_below(100) < 15) begin
      return specials[rand_below(10)];
    end
    return {(rand_below(10) == 0), 8'(107 + rand_below(42)), 7'(rand32())};
  endfunction

  // IEEE binary32 to double: exact for every encoding (NaN gives a NaN).
  function automatic real f32_to_real(input logic [31:0] f);
    logic [63:0] d;
    logic [22:0] man;
    int          lead;
    man = f[22:0];
    if (f[30:23] == 8'hff) begin
      if (man != '0) begin
        d = 64'h7ff8_0000_0000_0000;
      end else begin
        d = {f[31], 11'h7ff, 52'h0};
      end
    end else if (f[30:23] == 8'h00) begin
      if (man == '0) begin
        d = {f[31], 63'h0};
      end else begin
        // Subnormal: man * 2^-149, normalized for double.
        lead = 22;
        while (!man[lead]) begin
          lead--;
        end
        d = {f[31], 11'(lead - 149 + 1023), 52'(64'(man) << (52 - lead))};
      end
    end else begin
      d = {f[31], 11'(int'(f[30:23]) - 127 + 1023), man, 29'h0};
    end
    return $bitstoreal(d);
  endfunction

  // Double to IEEE binary32, round to nearest even, with subnormal results,
  // overflow to infinity and the canonical quiet NaN.
  function automatic logic [31:0] real_to_f32(input real r);
    logic [63:0] d;
    logic [52:0] sig;  // significand with the hidden bit
    logic [63:0] q;
    logic [63:0] rest;
    logic [63:0] half;
    int          e;  // unbiased exponent
    int          sh;
    d = $realtobits(r);
    if (d[62:52] == 11'h7ff) begin
      if (d[51:0] != '0) begin
        return F32_QNAN;
      end
      return {d[63], 8'hff, 23'h0};
    end
    if (d[62:52] == 11'h000) begin
      return {d[63], 31'h0};  // zero, or a double subnormal: far below binary32
    end
    sig = {1'b1, d[51:0]};
    e   = int'(d[62:52]) - 1023;
    if (e >= -126) begin
      // Normal result: keep 24 significand bits.
      q    = 64'(sig >> 29);
      rest = 64'(sig[28:0]);
      half = 64'h1000_0000;
    end else begin
      // Subnormal result: count in units of 2^-149.
      sh = -(e + 97);
      if (sh > 60) begin
        return {d[63], 31'h0};
      end
      q    = 64'(sig) >> sh;
      rest = 64'(sig) & ((64'h1 << sh) - 1);
      half = 64'h1 << (sh - 1);
    end
    if (rest > half || (rest == half && q[0])) begin
      q = q + 1;
    end
    if (e >= -126) begin
      if (q[24]) begin
        q = q >> 1;
        e = e + 1;
      end
      if (e > 127) begin
        return {d[63], 8'hff, 23'h0};
      end
      return {d[63], 8'(e + 127), q[22:0]};
    end
    // A subnormal that rounds up to 2^-126 becomes the smallest normal: q = 2^23.
    return {d[63], 31'(q)};
  endfunction

  function automatic real bf16_to_real(input logic [15:0] b);
    return f32_to_real({b, 16'h0000});
  endfunction

  // One lane of the stage: the new accumulator value.
  function automatic logic [31:0] lane_ref(input logic [31:0] acc, input bit first,
                                           input longint isum, input logic [15:0] sa,
                                           input logic [15:0] sb);
    logic [31:0] scale;
    logic [31:0] prod;
    logic [31:0] addend;
    scale  = real_to_f32(bf16_to_real(sa) * bf16_to_real(sb));
    prod   = real_to_f32(real'(isum) * f32_to_real(scale));
    addend = first ? 32'h0000_0000 : acc;
    return real_to_f32(f32_to_real(addend) + f32_to_real(prod));
  endfunction

  task automatic count_result(input logic [31:0] v);
    if (v[30:23] == 8'hff && v[22:0] != '0) begin
      nan_results++;
    end else if (v[30:23] == 8'hff) begin
      inf_results++;
    end else if (v[30:0] == '0) begin
      zero_results++;
    end else if (v[30:23] == 8'h00) begin
      subnormal_results++;
    end
    if (v[31] && v[30:0] != '0 && !(v[30:23] == 8'hff && v[22:0] != '0)) begin
      negative_results++;
    end
  endtask

  // Check what the stage registered at the last rising edge.
  task automatic check_outputs();
    int          slot;
    logic [31:0] got;
    if (out_valid === 1'b1) begin
      if (head == tail) begin
        errors++;
        $display("bpu_sa_scale_acc_tb: unexpected output row at cycle %0d", cycle);
      end else begin
        slot = head % QUEUE_DEPTH;
        if (cycle - exp_cycle[slot] != LATENCY_CYCLES) begin
          errors++;
          $display("bpu_sa_scale_acc_tb: row came %0d cycles after its input, expected %0d",
                   cycle - exp_cycle[slot], LATENCY_CYCLES);
        end
        if (out_last !== exp_last[slot]) begin
          errors++;
          $display("bpu_sa_scale_acc_tb: out_last_o = %b, expected %b", out_last, exp_last[slot]);
        end
        for (int j = 0; j < Cols; j++) begin
          got = out_row[32*j+:32];
          lanes_checked++;
          count_result(exp_row[slot][j]);
          if (got !== exp_row[slot][j]) begin
            errors++;
            if (errors <= 10) begin
              $display("bpu_sa_scale_acc_tb: MISMATCH output row %0d lane %0d: got %h want %h",
                       rows_checked, j, got, exp_row[slot][j]);
            end
          end
        end
        head++;
        rows_checked++;
      end
    end
  endtask

  // One falling edge: check, then drive idle with random junk payload.
  task automatic idle();
    @(negedge clk);
    cycle++;
    check_outputs();
    in_valid = 1'b0;
    in_row   = {(Cols * AccW + 31) / 32{rand32()}};
    in_idx   = ROW_IDX_WIDTH'(rand32());
    in_first = 1'(rand32());
    in_emit  = 1'(rand32());
    in_last  = 1'(rand32());
    in_sa    = 16'(rand32());
    in_sb    = {(Cols * 16 + 31) / 32{rand32()}};
  endtask

  // Enter row r at the next rising edge, after waiting out the row-spacing rule,
  // and model what the stage does with it.
  task automatic enter_row(input int r, input longint isum[Cols], input logic [15:0] sa,
                           input logic [15:0] sb[Cols], input bit first, input bit emit,
                           input bit last);
    int          slot;
    logic [31:0] v;
    while (cycle - last_entry[r] < MIN_SPACING) begin
      idle();
    end
    in_valid = 1'b1;
    in_idx   = ROW_IDX_WIDTH'(r);
    in_first = first;
    in_emit  = emit;
    in_last  = last;
    in_sa    = sa;
    for (int j = 0; j < Cols; j++) begin
      in_row[AccW*j+:AccW] = AccW'(isum[j]);
      in_sb[16*j+:16]      = sb[j];
    end
    slot = tail % QUEUE_DEPTH;
    for (int j = 0; j < Cols; j++) begin
      v = lane_ref(acc_ref[r][j], first, isum[j], sa, sb[j]);
      if (emit) begin
        exp_row[slot][j] = v;
      end else begin
        acc_ref[r][j] = v;
      end
    end
    if (emit) begin
      if (inject_error && !injected && rows_entered > 20) begin
        exp_row[slot][0] = exp_row[slot][0] ^ 32'h1;
        injected         = 1'b1;
      end
      exp_last[slot]  = last;
      exp_cycle[slot] = cycle;
      tail++;
    end
    last_entry[r] = cycle;
    rows_entered++;
    idle();
  endtask

  // A tile of g_count blocks with every lane given by the arrays; random row order,
  // and up to max_gap idle cycles between rows.
  task automatic run_tile(input int g_count, input longint isum[MAX_BLOCKS][Rows][Cols],
                          input logic [15:0] sa[MAX_BLOCKS][Rows],
                          input logic [15:0] sb[MAX_BLOCKS][Cols], input int max_gap);
    int            order   [Rows];
    int            pick;
    int            tmp;
    int            gap;
    longint        lanes   [Cols];
    logic   [15:0] block_sb[Cols];  // copied: some simulators reject array slices as arguments
    for (int g = 0; g < g_count; g++) begin
      for (int j = 0; j < Cols; j++) begin
        block_sb[j] = sb[g][j];
      end
      for (int r = 0; r < Rows; r++) begin
        order[r] = r;
      end
      for (int r = Rows - 1; r > 0; r--) begin
        pick        = rand_below(r + 1);
        tmp         = order[r];
        order[r]    = order[pick];
        order[pick] = tmp;
      end
      for (int n = 0; n < Rows; n++) begin
        for (int j = 0; j < Cols; j++) begin
          lanes[j] = isum[g][order[n]][j];
        end
        enter_row(order[n], lanes, sa[g][order[n]], block_sb, g == 0, g == g_count - 1,
                  g == g_count - 1 && n == Rows - 1);
        gap = (max_gap > 0) ? rand_below(max_gap + 1) : 0;
        repeat (gap) begin
          idle();
        end
      end
    end
    tiles_run++;
  endtask

  task automatic run_random_tile(input int max_gap);
    longint        isum    [MAX_BLOCKS][Rows] [Cols];
    logic   [15:0] sa      [MAX_BLOCKS][Rows];
    logic   [15:0] sb      [MAX_BLOCKS][Cols];
    int            g_count;
    g_count = 1 + rand_below(MAX_BLOCKS);
    for (int g = 0; g < g_count; g++) begin
      for (int r = 0; r < Rows; r++) begin
        sa[g][r] = rand_scale();
        for (int j = 0; j < Cols; j++) begin
          isum[g][r][j] = rand_isum();
        end
      end
      for (int j = 0; j < Cols; j++) begin
        sb[g][j] = rand_scale();
      end
    end
    run_tile(g_count, isum, sa, sb, max_gap);
  endtask

  // A directed tile: block g uses block_isum[g], block_sa[g] and block_sb[g] in every
  // lane of every row.
  task automatic run_directed(input int g_count, input longint block_isum[MAX_BLOCKS],
                              input logic [15:0] block_sa[MAX_BLOCKS],
                              input logic [15:0] block_sb[MAX_BLOCKS]);
    longint        isum[MAX_BLOCKS][Rows] [Cols];
    logic   [15:0] sa  [MAX_BLOCKS][Rows];
    logic   [15:0] sb  [MAX_BLOCKS][Cols];
    for (int g = 0; g < g_count; g++) begin
      for (int r = 0; r < Rows; r++) begin
        sa[g][r] = block_sa[g];
        for (int j = 0; j < Cols; j++) begin
          isum[g][r][j] = block_isum[g];
        end
      end
      for (int j = 0; j < Cols; j++) begin
        sb[g][j] = block_sb[g];
      end
    end
    run_tile(g_count, isum, sa, sb, 1);
  endtask

  // Reset while rows are in flight; check that none of them comes out.
  task automatic reset_mid_tile();
    longint        lanes   [Cols];
    logic   [15:0] sb      [Cols];
    int            entered;
    for (int j = 0; j < Cols; j++) begin
      sb[j] = 16'h3f80;
    end
    // Final-block rows (outputs expected), one per cycle where spacing allows.
    entered = 0;
    while (entered < 3 || (tail - head) == 0) begin
      for (int j = 0; j < Cols; j++) begin
        lanes[j] = rand_isum();
      end
      enter_row(entered % Rows, lanes, 16'h3f80, sb, 1'b1, 1'b1, 1'b0);
      entered++;
    end
    if (tail - head == 0) begin
      errors++;
      $display("bpu_sa_scale_acc_tb: reset test found no row in flight");
    end

    #2;  // between clock edges: an asynchronous assertion
    rst_n    = 1'b0;
    in_valid = 1'b0;
    #1;
    if (out_valid !== 1'b0) begin
      errors++;
      $display("bpu_sa_scale_acc_tb: out_valid_o did not drop at once on reset");
    end
    resets++;
    cancelled += tail - head;
    head = tail;
    repeat (3) begin
      @(negedge clk);
      cycle++;
      if (out_valid !== 1'b0) begin
        errors++;
        $display("bpu_sa_scale_acc_tb: out_valid_o rose while reset was held");
      end
    end
    rst_n = 1'b1;  // released on a falling edge, half a cycle before the next rising edge
    for (int r = 0; r < Rows; r++) begin
      last_entry[r] = -MIN_SPACING;  // the pipeline is empty again
    end
    // Cancelled rows must never appear: run idle past the pipeline latency.
    repeat (LATENCY_CYCLES + 2) begin
      idle();
    end
  endtask

  task automatic run_directed_set();
    longint        isum[MAX_BLOCKS];
    logic   [15:0] sa  [MAX_BLOCKS];
    logic   [15:0] sb  [MAX_BLOCKS];
    for (int n = 0; n < NUM_DIRECTED; n++) begin
      for (int g = 0; g < MAX_BLOCKS; g++) begin
        isum[g] = 0;
        sa[g]   = 16'h3f80;
        sb[g]   = 16'h3f80;
      end
      case (n)
        0: begin  // zero sum: +0
          run_directed(1, isum, sa, sb);
        end
        1: begin  // zero scale: +0
          isum[0] = 12345;
          sa[0]   = 16'h0000;
          run_directed(1, isum, sa, sb);
        end
        2: begin  // -0 products in both blocks must sum to +0
          sa[0] = 16'hbf80;
          sa[1] = 16'hbf80;
          run_directed(2, isum, sa, sb);
        end
        3: begin  // largest block sum
          isum[0] = ISUM_MAX;
          run_directed(1, isum, sa, sb);
        end
        4: begin  // smallest block sum
          isum[0] = ISUM_MIN;
          run_directed(1, isum, sa, sb);
        end
        5: begin  // exact cancellation across blocks: +0
          isum[0] = 12345;
          isum[1] = -12345;
          sa[0]   = 16'h3f00;
          sa[1]   = 16'h3f00;
          sb[0]   = 16'h4040;
          sb[1]   = 16'h4040;
          run_directed(2, isum, sa, sb);
        end
        6: begin  // scale product overflows to +inf
          isum[0] = 3;
          sa[0]   = 16'h7f7f;
          sb[0]   = 16'h7f7f;
          run_directed(1, isum, sa, sb);
        end
        7: begin  // +inf then -inf: NaN
          isum[0] = 3;
          isum[1] = -3;
          sa[0]   = 16'h7f7f;
          sa[1]   = 16'h7f7f;
          sb[0]   = 16'h7f7f;
          sb[1]   = 16'h7f7f;
          run_directed(2, isum, sa, sb);
        end
        8: begin  // NaN scale
          isum[0] = 5;
          sa[0]   = 16'h7fc0;
          run_directed(1, isum, sa, sb);
        end
        9: begin  // 0 * inf: NaN
          sa[0] = 16'h7f80;
          run_directed(1, isum, sa, sb);
        end
        10: begin  // scale product underflows to +0
          isum[0] = 1;
          sa[0]   = 16'h0001;
          sb[0]   = 16'h0080;
          run_directed(1, isum, sa, sb);
        end
        11: begin  // subnormal scale and result: 1 * 2^-127
          isum[0] = 1;
          sa[0]   = 16'h0080;
          sb[0]   = 16'h3f00;
          run_directed(1, isum, sa, sb);
        end
        12: begin  // negative infinity scale times the largest sum: -inf
          isum[0] = ISUM_MAX;
          sa[0]   = 16'hff80;
          run_directed(1, isum, sa, sb);
        end
        default: begin  // six blocks with rounding in every add
          for (int g = 0; g < MAX_BLOCKS; g++) begin
            isum[g] = ISUM_MAX - 2 * g;
            sa[g]   = 16'h3fab;
            sb[g]   = 16'h3d4d;
          end
          run_directed(MAX_BLOCKS, isum, sa, sb);
        end
      endcase
    end
  endtask

  initial begin : main
    if (!$value$plusargs("seed=%d", seed)) begin
      seed = Seed;
    end
    if (!$value$plusargs("inject_error=%d", inject_arg)) begin
      inject_arg = 0;
    end
    inject_error      = (inject_arg != 0);
    injected          = 1'b0;
    errors            = 0;
    rows_entered      = 0;
    rows_checked      = 0;
    lanes_checked     = 0;
    tiles_run         = 0;
    cancelled         = 0;
    resets            = 0;
    nan_results       = 0;
    inf_results       = 0;
    zero_results      = 0;
    subnormal_results = 0;
    negative_results  = 0;
    head              = 0;
    tail              = 0;
    cycle             = 0;
    rng_state         = seed ^ 32'h9e37_79b9;
    if (rng_state == 0) begin
      rng_state = 1;
    end
    for (int r = 0; r < Rows; r++) begin
      last_entry[r] = -MIN_SPACING;
      for (int j = 0; j < Cols; j++) begin
        acc_ref[r][j] = '0;
      end
    end

    rst_n    = 1'b0;
    in_valid = 1'b0;
    in_row   = '0;
    in_idx   = '0;
    in_first = 1'b0;
    in_emit  = 1'b0;
    in_last  = 1'b0;
    in_sa    = '0;
    in_sb    = '0;
    repeat (2) begin
      @(negedge clk);
    end
    rst_n = 1'b1;
    idle();

    // 1. directed boundary tiles
    run_directed_set();
    // 2. random tiles; every fourth one enters a row on every cycle it can
    for (int t = 0; t < Tiles; t++) begin
      run_random_tile((t % 4 == 3) ? 0 : 2);
    end
    // 3. reset with rows in flight
    reset_mid_tile();
    // 4. random tiles after the reset
    for (int t = 0; t < Tiles / 2; t++) begin
      run_random_tile((t % 4 == 3) ? 0 : 2);
    end
    repeat (LATENCY_CYCLES + 2) begin
      idle();
    end
    if (head != tail) begin
      errors++;
      $display("bpu_sa_scale_acc_tb: %0d expected rows never came out", tail - head);
    end

    if (errors != 0 || resets != 1 || cancelled == 0 || rows_checked == 0
        || tiles_run != NUM_DIRECTED + Tiles + Tiles / 2 || lanes_checked != rows_checked * Cols
        || nan_results == 0 || inf_results == 0 || zero_results == 0 || subnormal_results == 0
        || negative_results == 0) begin
      status = "FAIL";
    end else begin
      status = "PASS";
    end
    $write("RESULT bpu_sa_scale_acc_tb rows=%0d cols=%0d accw=%0d seed=%0d", Rows, Cols, AccW,
           seed);
    $write(" tiles=%0d rows_entered=%0d rows_checked=%0d lanes_checked=%0d", tiles_run,
           rows_entered, rows_checked, lanes_checked);
    $write(" nan=%0d inf=%0d zero=%0d subnormal=%0d negative=%0d", nan_results, inf_results,
           zero_results, subnormal_results, negative_results);
    $display(" cancelled=%0d resets=%0d cycles=%0d errors=%0d status=%s", cancelled, resets, cycle,
             errors, status);
    if (status != "PASS") begin
      $fatal(1, "bpu_sa_scale_acc_tb: FAIL (%0d errors)", errors);
    end
    $finish;
  end

endmodule
