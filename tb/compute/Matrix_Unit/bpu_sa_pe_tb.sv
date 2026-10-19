// Self-checking testbench for the output-stationary bpu_sa_pe: every signed
// int8 x int8 pair and every int8 x int4 pair through the accumulator and the
// capture, random traffic through the modes, the tile flags and the drain shift,
// block-scaled tiles through the scaling pipeline, and the flag reset.
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
//              random shadow inputs from below, unscaled. The scale inputs carry
//              random values, which must only pass through.
//              Model: first restarts the accumulator, last captures it into the
//              shadow, shift loads the shadow from below bit for bit, otherwise the
//              shadow holds.
//   4. scaled  (Scale = 1 only) ScaledTiles block-scaled tiles: 1 to 4 blocks of 1
//              to 16 k-steps (INT8 or INT4 pair per tile), 0 to 2 idle cycles
//              between blocks, random bf16 scales (normal, huge, giant, tiny,
//              zero, subnormal, inf and NaN), a fifth of the tiles all-extreme operands
//              (-128 x -128, or -128 x -8), a fifth continuing the previous tile's
//              sum (sfirst = 0), and a drain shift after some tiles.
//              Model: an independent reference in double precision (exact here:
//              every product has at most 35 significant bits) rounded to nearest
//              even into Q23.24, with saturation and the NaN and overflow flags; the
//              final block's packed result must reach the shadow SCALE_PIPE edges
//              after the block end.
//   5. reset   rst_n is asserted between clock edges with first = last = 1 driven:
//              first_o and last_o must drop at once and stay 0 until release.
//
// Checks every cycle: a_o, b_o, first_o, last_o (and with Scale sa_o, sb_o,
// sfirst_o, slast_o) are the inputs of the previous cycle; the shadow outputs match
// the model (sum + carry after an unscaled capture, the exact bits after a shift or
// a scaled capture). The run ends with $fatal(1, ...) on any mismatch, on a wrong
// check count, if a required case never occurred (with Scale: a saturation, a NaN, a
// contribution rounded to zero, a subnormal scale that only the flush keeps out of
// the sum, a continued tile, a drained scaled result) or on
// timeout, and prints one RESULT line for the regression runner
// (tb/compute/Matrix_Unit/run_tests.sh).
//
// Parameters: AccW, Int4, Scale and BsumW (the PE under test), TrafficCycles,
// ScaledTiles, Seed (the default seed).
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
  parameter bit Scale = 1'b1;
  parameter int BsumW = 20;
  parameter int TrafficCycles = 20000;
  parameter int ScaledTiles = 3000;
  parameter int Seed = 1;

  localparam int PAIRS = 256 * 256;
  localparam int INT4_PAIRS = Int4 ? 2 * 256 * 16 : 0;  // both halves
  localparam int AW = Int4 ? 16 : 8;  // A path width
  localparam int SCALE_PIPE = 4;  // bpu_sa_pkg::SCALE_PIPE
  localparam int FX_W = 48;  // bpu_sa_pkg::FX_W
  localparam longint FX_MAX = (64'sd1 <<< (FX_W - 1)) - 1;
  localparam longint FX_MIN = -(64'sd1 <<< (FX_W - 1));
  localparam int TILES = Scale ? ScaledTiles : 0;
  localparam int TIMEOUT_CYCLES = 2 * (PAIRS + INT4_PAIRS) + TrafficCycles + 100 * TILES + 1000;

  logic                   clk;
  logic                   rst_n;
  logic        [  AW-1:0] a;
  logic                   mode;
  logic                   scaled;
  logic                   first;
  logic                   last;
  logic                   sfirst;
  logic                   slast;
  logic        [    15:0] sa;
  logic        [  AW-1:0] a_out;
  logic                   first_out;
  logic                   last_out;
  logic                   sfirst_out;
  logic                   slast_out;
  logic        [    15:0] sa_out;
  logic        [     7:0] b;
  logic        [    15:0] sb;
  logic        [     7:0] b_out;
  logic        [    15:0] sb_out;
  logic                   shift;
  logic        [AccW-1:0] shd_sum_in;
  logic        [AccW-1:0] shd_carry_in;
  logic        [AccW-1:0] shd_sum_out;
  logic        [AccW-1:0] shd_carry_out;

  // Reference model: the accumulator value, and the shadow either as a value
  // (after an unscaled capture) or as exact sum and carry bits (after a shift or a
  // scaled capture).
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
  logic                   prev_sfirst;
  logic                   prev_slast;
  logic        [    15:0] prev_sa;
  logic        [    15:0] prev_sb;
  // Scaled reference: the fixed-point accumulator and its flags, and the packed
  // results on their way to the shadow (index SCALE_PIPE - 1 lands next).
  longint                 fx_acc;
  bit                     fx_ovf;
  bit                     fx_nan;
  bit                     mp_valid           [SCALE_PIPE];
  logic        [    63:0] mp_pack            [SCALE_PIPE];

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
  int                     steps;
  int                     captures;
  int                     shifts;
  int                     restarts;
  int                     reset_checks;
  int                     scaled_blocks;
  int                     scaled_captures;
  int                     scaled_continued;
  int                     saturations;
  int                     nans;
  int                     rounded_to_zero;
  int                     flushed_subnormals;
  string                  status;

  bpu_sa_pe #(
    .AccW (AccW),
    .Int4 (Int4),
    .Scale(Scale),
    .BsumW(BsumW)
  ) u_dut (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .mode_i     (mode),
    .scaled_i   (scaled),
    .a_i        (a),
    .first_i    (first),
    .last_i     (last),
    .sfirst_i   (sfirst),
    .slast_i    (slast),
    .sa_i       (sa),
    .a_o        (a_out),
    .first_o    (first_out),
    .last_o     (last_out),
    .sfirst_o   (sfirst_out),
    .slast_o    (slast_out),
    .sa_o       (sa_out),
    .b_i        (b),
    .sb_i       (sb),
    .b_o        (b_out),
    .sb_o       (sb_out),
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

  // A bf16 scale: mostly normal near 1, with huge, giant, tiny, zero, subnormal, inf
  // and NaN values mixed in. Only a giant scale (2^97 or more) lifts a subnormal one
  // to the 2^-24 LSB, so the pair checks that subnormals are flushed to zero.
  function automatic logic [15:0] rand_scale();
    int         pick;
    logic       sign;
    logic [6:0] mant;
    pick = rand_below(100);
    sign = (rand_below(100) < 20);
    mant = 7'(rand32());
    if (pick < 60) begin
      return {sign, 8'(127 - 14 + rand_below(17)), mant};  // 2^-14 .. 2^2
    end else if (pick < 67) begin
      return {sign, 8'(127 + 12 + rand_below(30)), mant};  // huge: saturates
    end else if (pick < 72) begin
      return {sign, 8'(224 + rand_below(31)), mant};  // giant: 2^97 .. 2^127
    end else if (pick < 80) begin
      return {sign, 8'(1 + rand_below(80)), mant};  // tiny: rounds to (near) zero
    end else if (pick < 86) begin
      return {sign, 8'h00, 7'h00};  // zero
    end else if (pick < 92) begin
      return {sign, 8'h00, (mant == 7'h00) ? 7'h01 : mant};  // subnormal: counts as zero
    end else if (pick < 96) begin
      return {sign, 8'hff, 7'h00};  // inf
    end else begin
      return {sign, 8'hff, (mant == 7'h00) ? 7'h40 : mant};  // NaN
    end
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

  // 2^n as a real, exact (doubling and halving are exact in binary floating point).
  function automatic real pow2(input int n);
    real r;
    r = 1.0;
    for (int i = 0; i < n; i++) begin
      r = r * 2.0;
    end
    for (int i = 0; i > n; i--) begin
      r = r / 2.0;
    end
    return r;
  endfunction

  // bf16 as a real, exact; exponent 0 (zero and subnormals) counts as zero.
  function automatic real bf16_value(input logic [15:0] h);
    real v;
    if (h[14:7] == 8'h00) begin
      return 0.0;
    end
    v = real'(128 + int'(h[6:0])) * pow2(int'(h[14:7]) - 127 - 7);
    return h[15] ? -v : v;
  endfunction

  // Round a real holding an exact value to the nearest integer, ties to even.
  function automatic longint round_even(input real x);
    real    fl;
    longint q;
    fl = $floor(x);
    q  = longint'(fl);
    if (x - fl > 0.5 || (x - fl == 0.5 && q % 2 != 0)) begin
      q = q + 1;
    end
    return q;
  endfunction

  // One block into the scaled reference: fx_acc += round(isum * sa * sb * 2^24),
  // saturating, with sticky overflow and NaN flags; restart clears them first.
  task automatic fx_block(input longint isum, input logic [15:0] sx, input logic [15:0] sy,
                          input bit restart);
    real    x;
    longint c;
    longint s;
    if (restart) begin
      fx_acc = 0;
      fx_ovf = 1'b0;
      fx_nan = 1'b0;
    end
    if (sx[14:7] == 8'hff || sy[14:7] == 8'hff) begin
      fx_nan = 1'b1;
      nans++;
      return;
    end
    // A subnormal scale times a giant one, |isum| >= 64, nothing saturated yet: without
    // the flush this block would add at least one LSB.
    if (!fx_ovf && (isum >= 64 || isum <= -64)
        && ((sx[14:7] == 8'h00 && sx[6:0] != 7'h00 && sy[14:7] >= 8'd224)
        || (sy[14:7] == 8'h00 && sy[6:0] != 7'h00 && sx[14:7] >= 8'd224))) begin
      flushed_subnormals++;
    end
    x = real'(isum) * bf16_value(sx) * bf16_value(sy) * pow2(24);
    if (x >= pow2(62) || x <= -pow2(62)) begin
      fx_acc = (x < 0.0) ? FX_MIN : FX_MAX;
      fx_ovf = 1'b1;
      saturations++;
      return;
    end
    c = round_even(x);
    if (c == 0 && x != 0.0) begin
      rounded_to_zero++;
    end
    if (c > FX_MAX || c < FX_MIN) begin
      fx_acc = (x < 0.0) ? FX_MIN : FX_MAX;
      fx_ovf = 1'b1;
      saturations++;
      return;
    end
    s = fx_acc + c;
    if (s > FX_MAX) begin
      fx_acc = FX_MAX;
      fx_ovf = 1'b1;
      saturations++;
    end else if (s < FX_MIN) begin
      fx_acc = FX_MIN;
      fx_ovf = 1'b1;
      saturations++;
    end else begin
      fx_acc = s;
    end
  endtask

  // Model the rising edge for the inputs driven now.
  task automatic model_edge();
    logic   [  AccW-1:0] p;
    logic   [2*AccW-1:0] packed_bits;
    longint              isum;
    // A scaled result whose pipeline ends at this edge lands in the shadow.
    if (mp_valid[SCALE_PIPE-1]) begin
      shd_sum_exp   = mp_pack[SCALE_PIPE-1][AccW-1:0];
      shd_carry_exp = mp_pack[SCALE_PIPE-1][2*AccW-1:AccW];
      shd_exact     = 1'b1;
      shd_known     = 1'b1;
      scaled_captures++;
    end
    for (int n = SCALE_PIPE - 1; n > 0; n--) begin
      mp_valid[n] = mp_valid[n-1];
      mp_pack[n]  = mp_pack[n-1];
    end
    mp_valid[0] = 1'b0;

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
    if (last && Scale && scaled) begin
      isum = longint'($signed(acc_val));
      fx_block(isum, sa, sb, sfirst);
      scaled_blocks++;
      if (slast) begin
        packed_bits = (2 * AccW)'({fx_nan, fx_ovf, fx_acc[FX_W-1:0]});
        if (inject_error && !injected && scaled_blocks > 10) begin
          packed_bits = packed_bits ^ 1;
          injected    = 1'b1;
        end
        mp_valid[0] = 1'b1;
        mp_pack[0]  = 64'(packed_bits);
      end
    end else if (last) begin
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
    if (inject_error && !injected && !Scale && shd_known && !shd_exact && captures > 3) begin
      shd_val  = shd_val + 1'b1;
      injected = 1'b1;
    end
    prev_a      = a;
    prev_b      = b;
    prev_first  = first;
    prev_last   = last;
    prev_sfirst = sfirst;
    prev_slast  = slast;
    prev_sa     = sa;
    prev_sb     = sb;
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
    if (Scale && (sa_out !== prev_sa || sb_out !== prev_sb || sfirst_out !== prev_sfirst
                  || slast_out !== prev_slast)) begin
      errors++;
      if (errors <= 10) begin
        $display("bpu_sa_pe_tb: scale outputs sa=%h sb=%h sfirst=%b slast=%b, want %h %h %b %b",
                 sa_out, sb_out, sfirst_out, slast_out, prev_sa, prev_sb, prev_sfirst, prev_slast);
      end
    end
    if (shd_known) begin
      if (shd_exact) begin
        if (shd_sum_out !== shd_sum_exp || shd_carry_out !== shd_carry_exp) begin
          errors++;
          if (errors <= 10) begin
            $display("bpu_sa_pe_tb: shadow bits %h/%h, want %h/%h (cycle check %0d)", shd_sum_out,
                     shd_carry_out, shd_sum_exp, shd_carry_exp, cycle_checks);
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
    steps++;
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

  task automatic idle(input int n);
    a      = '0;
    b      = '0;
    first  = 1'b0;
    last   = 1'b0;
    sfirst = 1'b0;
    slast  = 1'b0;
    shift  = 1'b0;
    repeat (n) begin
      step();
    end
  endtask

  // One block-scaled tile of 1 to 4 blocks; extreme: every operand at its negative
  // limit, so each block sum is the largest positive one.
  task automatic scaled_tile(input bit restart, input bit extreme);
    int nb;
    int len;
    nb   = 1 + rand_below(4);
    mode = Int4 && (rand_below(2) == 1);
    for (int g = 0; g < nb; g++) begin
      len = 1 + rand_below(16);
      for (int k = 0; k < len; k++) begin
        if (extreme) begin
          a = AW'(16'h8080);
          b = mode ? 8'h88 : 8'h80;  // -128 x -128, or -128 x -8 in both INT4 halves
        end else begin
          a = AW'(rand32());
          b = 8'(rand32());
        end
        first  = (k == 0);
        last   = (k == len - 1);
        sfirst = last && (g == 0) && restart;
        slast  = last && (g == nb - 1);
        sa     = last ? rand_scale() : 16'(rand32());
        sb     = last ? rand_scale() : 16'(rand32());
        step();
      end
      idle(rand_below(3));
    end
    if (!restart) begin
      scaled_continued++;
    end
    idle(SCALE_PIPE);  // the final result lands in the shadow (checked every cycle)
    if (rand_below(4) == 0) begin
      shift        = 1'b1;  // drain it, with fresh bits from below
      shd_sum_in   = rand_acc();
      shd_carry_in = rand_acc();
      step();
      shift = 1'b0;
    end
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
    inject_error       = (inject_arg != 0);
    injected           = 1'b0;
    errors             = 0;
    pair_checks        = 0;
    int4_pair_checks   = 0;
    int4_cycles        = 0;
    cycle_checks       = 0;
    steps              = 0;
    captures           = 0;
    shifts             = 0;
    restarts           = 0;
    reset_checks       = 0;
    scaled_blocks      = 0;
    scaled_captures    = 0;
    scaled_continued   = 0;
    saturations        = 0;
    nans               = 0;
    rounded_to_zero    = 0;
    flushed_subnormals = 0;
    shd_known          = 1'b0;
    shd_exact          = 1'b0;
    acc_val            = '0;
    fx_acc             = 0;
    fx_ovf             = 1'b0;
    fx_nan             = 1'b0;
    for (int n = 0; n < SCALE_PIPE; n++) begin
      mp_valid[n] = 1'b0;
      mp_pack[n]  = '0;
    end
    rng_state = seed ^ 32'h9e37_79b9;
    if (rng_state == 0) begin
      rng_state = 1;
    end

    rst_n        = 1'b0;
    mode         = 1'b0;
    scaled       = 1'b0;
    a            = '0;
    b            = '0;
    first        = 1'b0;
    last         = 1'b0;
    sfirst       = 1'b0;
    slast        = 1'b0;
    sa           = '0;
    sb           = '0;
    shift        = 1'b0;
    shd_sum_in   = '0;
    shd_carry_in = '0;
    prev_a       = '0;
    prev_b       = '0;
    prev_first   = 1'b0;
    prev_last    = 1'b0;
    prev_sfirst  = 1'b0;
    prev_slast   = 1'b0;
    prev_sa      = '0;
    prev_sb      = '0;
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

    // 3. random modes, flags, data and drain shifts; the scale inputs only pass through
    for (int c = 0; c < TrafficCycles; c++) begin
      mode         = Int4 && (rand_below(2) == 1);
      a            = AW'(rand32());
      b            = 8'(rand32());
      first        = (rand_below(100) < 15);
      last         = (rand_below(100) < 15);
      sfirst       = (rand_below(2) == 1);
      slast        = (rand_below(2) == 1);
      sa           = 16'(rand32());
      sb           = 16'(rand32());
      shift        = !last && (rand_below(100) < 30);
      shd_sum_in   = rand_acc();
      shd_carry_in = rand_acc();
      step();
    end
    idle(1);

    // 4. block-scaled tiles
    if (Scale) begin
      scaled = 1'b1;
      for (int t = 0; t < TILES; t++) begin
        scaled_tile(t == 0 || rand_below(5) != 0, rand_below(5) == 0);
      end
      scaled = 1'b0;
    end

    // 5. reset clears the flag outputs at once and holds them at 0
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
        || cycle_checks != steps || steps < 2 * (PAIRS + INT4_PAIRS) + TrafficCycles
        || shifts == 0 || captures <= PAIRS || reset_checks != 3 || (Int4 && int4_cycles == 0)
        || (Scale && (scaled_captures < TILES || scaled_continued == 0 || saturations == 0
                      || nans == 0 || rounded_to_zero == 0 || flushed_subnormals == 0)))
        begin
      status = "FAIL";
    end else begin
      status = "PASS";
    end
    $write("RESULT bpu_sa_pe_tb accw=%0d int4=%0d scale=%0d seed=%0d pair_checks=%0d", AccW, Int4,
           Scale, seed, pair_checks);
    $write(" int4_pair_checks=%0d int4_cycles=%0d cycle_checks=%0d", int4_pair_checks, int4_cycles,
           cycle_checks);
    $write(" captures=%0d shifts=%0d restarts=%0d reset_checks=%0d", captures, shifts, restarts,
           reset_checks);
    $write(" scaled_blocks=%0d scaled_captures=%0d continued=%0d saturations=%0d nans=%0d",
           scaled_blocks, scaled_captures, scaled_continued, saturations, nans);
    $display(" rounded_to_zero=%0d flushed_subnormals=%0d errors=%0d status=%s", rounded_to_zero,
             flushed_subnormals, errors, status);
    if (status != "PASS") begin
      $fatal(1, "bpu_sa_pe_tb: FAIL (%0d errors)", errors);
    end
    $finish;
  end

endmodule
