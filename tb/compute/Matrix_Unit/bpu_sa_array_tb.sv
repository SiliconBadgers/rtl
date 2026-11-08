// Self-checking testbench for the output-stationary bpu_sa_array: random tiles of
// random length against a reference model, a stall-free streaming phase, a reset in
// the middle of active work, and the mode error. One arithmetic mode per run:
// INT8 (Mode = 0) or INT4 pair (Mode = 1: INT8 A x INT4 B, two k-steps per
// transfer); unscaled (Scaled = 0) or block-scaled (Scaled = 1: every tile is split
// into blocks of 1 to BlockK k-steps with random bf16 row and column scales, and
// the drained results are the packed fixed-point values).
//
// One array configuration per run; the regression runner
// (tb/compute/Matrix_Unit/run_tests.sh) runs several shapes and seeds.
//
// Parameters: Rows, Cols, AccW, Int4, Scale, BlockK (the array under test), Mode,
// Scaled, TrafficCycles
// (cycles per traffic phase), StreamTiles, Seed (the default seed) and ResetWaitCycles
// (the most extra stimulus cycles to wait for the active-reset scenario).
// Plusargs:
//   +seed=<n>       random seed (default: Seed)
//   +inject_error=1 corrupt one expected value on purpose; the run must FAIL
//
// Phases
//   1. traffic  TrafficCycles cycles. Tiles of random K (often 1 to 3, so the
//               last-k-step gate stalls; up to 6 * (Rows + Cols) + 8). The producer
//               offers a k-step on 70% of cycles and is legal: a stalled k-step
//               stays offered, unchanged, until accepted. The consumer is ready on
//               65% of cycles.
//   2. stream   StreamTiles tiles of K = 2 * Rows + Cols (+ SCALE_PIPE block-scaled)
//               with the producer
//               always valid and the consumer always ready. After the first tile
//               no k-step may stall: the documented stall-free condition.
//   3. reset    rst_n is asserted between clock edges while a tile accumulates and
//               the previous one drains, held 3 cycles, released on a falling edge.
//               out_valid_o must drop at once and in_ready_o must be 1; all accepted
//               work is cancelled and the producer restarts with in_first_i = 1.
//               The run stops with $fatal ("active-reset precondition not reached")
//               if no such point is reached within ResetWaitCycles; the runner's
//               --check-reset-guard sets TrafficCycles = ResetWaitCycles = 0 to
//               prove it. Reset is asserted after the rising edge that accepts the
//               prepared transfer, so the model and the hardware agree on the work.
//   4. traffic  As phase 1. Every row must again match the model, so nothing from
//               before the reset leaks through.
//   5. drain    Remaining rows come out; then err_mode_o must be high for
//               mode_i = 1 exactly when the build has no Int4.
//
// Block-scaled model: each block's exact integer sums, scaled by sA[i] * sB[j] in an
// independent double-precision reference (exact here) rounded to nearest even into
// Q23.24, saturating, with sticky NaN and overflow flags (as bpu_sa_pe documents); a
// fifth of the tiles continue the previous tile's sums (in_sfirst_i = 0), the
// others restart them. Scales outside a block's last k-step are junk the array must
// ignore.
//
// Checks: every C row against the model, in order, with out_row_idx_o and
// out_last_o; the first row of each tile exactly Rows + Cols (+ SCALE_PIPE
// block-scaled) falling edges after the edge that accepted its final k-step (one
// rising edge fewer, as documented); no row when none is expected; in_ready_o =
// !(final k-step && tile busy) every cycle; err_mode_o; in INT8 mode, junk in the
// unused high byte of each A lane changes nothing; and InStallStable_A, an independent
// monitor that a stalled k-step keeps in_valid_i and its payload stable. The run
// ends with $fatal(1, ...) on any error, on a count mismatch or on timeout, and
// prints one RESULT line for the runner.
//
// Scheduling: stimulus is driven and outputs are checked on the falling clock edge;
// the design samples on the rising edge.
module bpu_sa_array_tb;
  timeunit 1ns; timeprecision 1ps;

  parameter int Rows = 8;
  parameter int Cols = 8;
  parameter int AccW = 32;
  parameter bit Int4 = 1'b1;
  parameter bit Scale = 1'b1;
  parameter int BlockK = 16;
  parameter bit Mode = 1'b0;  // 1: INT4 pair (needs Int4)
  parameter bit Scaled = 1'b0;  // 1: block-scaled (needs Scale)
  parameter int TrafficCycles = 3000;
  parameter int ResetWaitCycles = 2000;
  parameter int StreamTiles = 6;
  parameter int Seed = 1;

  localparam int SCALE_PIPE = 4;  // bpu_sa_pkg::SCALE_PIPE
  localparam int FX_W = 48;  // bpu_sa_pkg::FX_W
  localparam int FX_PACK_W = FX_W + 2;
  localparam longint FX_MAX = (64'sd1 <<< (FX_W - 1)) - 1;
  localparam longint FX_MIN = -(64'sd1 <<< (FX_W - 1));
  // Falling edges, final k-step to row 0.
  localparam int LATENCY_CYCLES = Rows + Cols + (Scaled ? SCALE_PIPE : 0);
  localparam int STREAM_K = 2 * Rows + Cols + (Scaled ? SCALE_PIPE : 0);
  localparam int BLOCK_STEPS = Mode ? BlockK / 2 : BlockK;  // transfers per block, at most
  localparam int MAX_K = 6 * (Rows + Cols) + 8;
  localparam int QUEUE_DEPTH = 4;  // finished tiles waiting to drain (at most 2)
  localparam int ROW_IDX_WIDTH = $clog2((Rows > 1) ? Rows : 2);
  localparam int AW = Int4 ? 16 : 8;  // bits per A lane
  localparam int TIMEOUT_CYCLES = 3 * TrafficCycles + (StreamTiles + 4) * (STREAM_K + 2 * Rows)
      + 40 * LATENCY_CYCLES + 4000;

  logic clk;
  logic rst_n;
  logic mode;
  logic scaled;
  logic err_mode;
  logic in_valid;
  logic in_ready;
  logic [Rows*AW-1:0] in_a;
  logic [Cols*8-1:0] in_b;
  logic in_first;
  logic in_last;
  logic [Rows*16-1:0] in_sa;
  logic [Cols*16-1:0] in_sb;
  logic in_sfirst;
  logic in_slast;
  logic out_valid;
  logic out_ready;
  logic [Cols*AccW-1:0] out_row;
  logic [Cols*FX_PACK_W-1:0] out_fx;
  logic [ROW_IDX_WIDTH-1:0] out_row_idx;
  logic out_last;

  // Producer: the tile being sent and the k-step on offer.
  int tile_k;  // K of the tile being sent
  int next_k;  // index of the next k-step to send
  int a_vals[Rows];  // A[i][k]
  int a_hi[Rows];  // A[i][k+1] (INT4 pair)
  int b_vals[Cols];  // B[k][j]
  int b_hi[Cols];  // B[k+1][j] (INT4 pair)
  longint acc[Rows][Cols];
  bit in_hold;
  // Block-scaled producer and model: the block on offer, the tile's choice to
  // restart the scaled sums, the scales, and each element's scaled sum and flags.
  int blk_len;
  int blk_pos;
  bit blk_first;  // the tile's first block
  bit tile_restart;
  logic [15:0] sa_vals[Rows];
  logic [15:0] sb_vals[Cols];
  longint fx_acc[Rows][Cols];
  bit fx_ovf[Rows][Cols];
  bit fx_nan[Rows][Cols];
  bit fx_known;  // a tile has restarted the scaled sums since reset

  // Finished tiles, oldest first, and the drain position in the oldest.
  longint exp_val[QUEUE_DEPTH][Rows][Cols];
  int exp_cycle[QUEUE_DEPTH];
  int head;
  int tail;
  int row_ptr;
  bit busy;  // model of the array's tile-busy state

  // Phase controls.
  int valid_pct;
  int ready_pct;
  bit allow_new;
  bit stream_k;
  bit count_stalls;

  // Run control and statistics.
  int cycle;
  int seed;
  int unsigned rng_state;
  bit inject_error;
  int inject_arg;
  bit injected;
  int errors;
  int ksteps;
  int tiles_sent;
  int tiles_done;
  int rows_checked;
  int cancelled;
  int in_stalls;
  int stream_stalls;
  int stream_tiles_done;
  int out_stalls;
  int resets;
  int active_resets;
  int mode_checks;
  int blocks;
  int continued_tiles;
  int fx_nans;
  int fx_saturations;
  string status;

  // Stall-stability monitor state.
  bit prev_stall;
  logic [Rows*AW+Cols*8+Rows*16+Cols*16+3:0] prev_payload;

  bpu_sa_array #(
    .Rows  (Rows),
    .Cols  (Cols),
    .AccW  (AccW),
    .Int4  (Int4),
    .Scale (Scale),
    .BlockK(BlockK)
  ) u_dut (
    .clk_i        (clk),
    .rst_ni       (rst_n),
    .mode_i       (mode),
    .scaled_i     (scaled),
    .err_mode_o   (err_mode),
    .in_valid_i   (in_valid),
    .in_ready_o   (in_ready),
    .in_a_i       (in_a),
    .in_b_i       (in_b),
    .in_first_i   (in_first),
    .in_last_i    (in_last),
    .in_sa_i      (in_sa),
    .in_sb_i      (in_sb),
    .in_sfirst_i  (in_sfirst),
    .in_slast_i   (in_slast),
    .out_valid_o  (out_valid),
    .out_ready_i  (out_ready),
    .out_row_o    (out_row),
    .out_fx_o     (out_fx),
    .out_row_idx_o(out_row_idx),
    .out_last_o   (out_last)
  );

  initial begin : config_check
    if (Mode && !Int4) begin
      $fatal(1, "bpu_sa_array_tb: Mode = 1 needs Int4 = 1");
    end
    if (Scaled && !Scale) begin
      $fatal(1, "bpu_sa_array_tb: Scaled = 1 needs Scale = 1");
    end
  end

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

  // A stalled k-step (valid high, ready low at a rising edge) must still be offered,
  // unchanged, at the next rising edge. Independent of the stimulus generator.
  always @(posedge clk) begin : in_stall_monitor
    if (!rst_n) begin
      prev_stall <= 1'b0;
    end else begin
      if (prev_stall) begin
        InStallStable_A :
        assert (in_valid === 1'b1
                && {in_a, in_b, in_sa, in_sb, in_first, in_last, in_sfirst, in_slast}
                   === prev_payload)
        else begin
          errors++;
          $display("bpu_sa_array_tb: stalled k-step was withdrawn or changed");
        end
      end
      prev_stall   <= in_valid && !in_ready;
      prev_payload <= {in_a, in_b, in_sa, in_sb, in_first, in_last, in_sfirst, in_slast};
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

  // A random int4, with each extreme (-8, 7) chosen 10% of the time.
  function automatic int rand_int4();
    int u;
    u = rand_below(10);
    if (u == 0) begin
      return -8;
    end
    if (u == 1) begin
      return 7;
    end
    return rand_below(16) - 8;
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

  // A bf16 scale: mostly normal (2^-14 .. 2^2), with zero, subnormal, huge, tiny,
  // inf and NaN values now and then.
  function automatic logic [15:0] rand_scale();
    int         u;
    logic       sign;
    logic [6:0] mant;
    u    = rand_below(1000);
    sign = (rand_below(100) < 20);
    mant = 7'(rand32());
    if (u < 900) begin
      return {sign, 8'(127 - 14 + rand_below(17)), mant};
    end else if (u < 940) begin
      return {sign, 8'h00, 7'h00};
    end else if (u < 960) begin
      return {sign, 8'h00, (mant == 7'h00) ? 7'h01 : mant};
    end else if (u < 975) begin
      return {sign, 8'(127 + 16 + rand_below(20)), mant};
    end else if (u < 995) begin
      return {sign, 8'(1 + rand_below(60)), mant};
    end else begin
      return {sign, 8'hff, mant};
    end
  endfunction

  // 2^n as a real, exact.
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

  // One block into element (i, j)'s scaled sum: + round(isum * sa * sb * 2^24),
  // saturating, with sticky overflow and NaN flags; restart clears them first.
  task automatic fx_block(input int i, input int j, input longint isum, input bit restart);
    real    x;
    longint c;
    longint t;
    if (restart) begin
      fx_acc[i][j] = 0;
      fx_ovf[i][j] = 1'b0;
      fx_nan[i][j] = 1'b0;
    end
    if (sa_vals[i][14:7] == 8'hff || sb_vals[j][14:7] == 8'hff) begin
      fx_nan[i][j] = 1'b1;
      fx_nans++;
      return;
    end
    x = real'(isum) * bf16_value(sa_vals[i]) * bf16_value(sb_vals[j]) * pow2(24);
    if (x >= pow2(62) || x <= -pow2(62)) begin
      c = (x < 0.0) ? FX_MIN - 1 : FX_MAX + 1;  // out of range either way
    end else begin
      c = round_even(x);
    end
    if (c > FX_MAX || c < FX_MIN) begin
      fx_acc[i][j] = (x < 0.0) ? FX_MIN : FX_MAX;
      fx_ovf[i][j] = 1'b1;
      fx_saturations++;
      return;
    end
    t = fx_acc[i][j] + c;
    if (t > FX_MAX || t < FX_MIN) begin
      fx_acc[i][j] = (t > FX_MAX) ? FX_MAX : FX_MIN;
      fx_ovf[i][j] = 1'b1;
      fx_saturations++;
    end else begin
      fx_acc[i][j] = t;
    end
  endtask

  // Element (i, j)'s packed result: {nan, overflow, value}.
  function automatic longint fx_packed(input int i, input int j);
    logic [63:0] v;
    v = fx_acc[i][j];
    return longint'({fx_nan[i][j], fx_ovf[i][j], v[FX_W-1:0]});
  endfunction

  function automatic int rand_tile_k();
    int u;
    if (stream_k) begin
      return STREAM_K;
    end
    u = rand_below(10);
    if (u < 3) begin
      return 1 + rand_below(3);
    end
    if (u < 8) begin
      return 1 + rand_below(2 * (Rows + Cols) + 4);
    end
    return 1 + rand_below(MAX_K);
  endfunction

  task automatic new_tile();
    tile_k       = rand_tile_k();
    next_k       = 0;
    blk_pos      = 0;
    blk_first    = 1'b1;
    tile_restart = !fx_known || (rand_below(5) != 0);
  endtask

  // Check the outputs the design registered at the last rising edge; they depend
  // only on registers, so they are what the next rising edge samples.
  task automatic check_outputs();
    logic [     AccW-1:0] want;
    logic [FX_PACK_W-1:0] want_fx;
    int                   slot;
    if (out_valid === 1'b1) begin
      if (head == tail) begin
        errors++;
        $display("bpu_sa_array_tb: unexpected C row at cycle %0d", cycle);
      end else begin
        slot = head % QUEUE_DEPTH;
        if (row_ptr == 0 && exp_cycle[slot] >= 0) begin
          if (cycle - exp_cycle[slot] != LATENCY_CYCLES) begin
            errors++;
            $display("bpu_sa_array_tb: tile %0d row 0 came %0d cycles after its last k-step, %s%0d",
                     tiles_done, cycle - exp_cycle[slot], "expected ", LATENCY_CYCLES);
          end
          exp_cycle[slot] = -1;  // latency checked once per tile
        end
        if (out_row_idx !== ROW_IDX_WIDTH'(row_ptr) || out_last !== (row_ptr == Rows - 1)) begin
          errors++;
          $display("bpu_sa_array_tb: row index %0d last %b, expected %0d %b", out_row_idx,
                   out_last, row_ptr, row_ptr == Rows - 1);
        end
        for (int j = 0; j < Cols; j++) begin
          if (Scaled) begin
            want_fx = exp_val[slot][row_ptr][j][FX_PACK_W-1:0];
            if (out_fx[j*FX_PACK_W+:FX_PACK_W] !== want_fx) begin
              errors++;
              if (errors <= 10) begin
                $display("bpu_sa_array_tb: MISMATCH tile %0d C[%0d][%0d]: got %h want %h",
                         tiles_done, row_ptr, j, out_fx[j*FX_PACK_W+:FX_PACK_W], want_fx);
              end
            end
          end else begin
            want = exp_val[slot][row_ptr][j][AccW-1:0];
            if (out_row[j*AccW+:AccW] !== want) begin
              errors++;
              if (errors <= 10) begin
                $display("bpu_sa_array_tb: MISMATCH tile %0d C[%0d][%0d]: got %0d want %0d",
                         tiles_done, row_ptr, j, $signed(out_row[j*AccW+:AccW]), $signed(want));
              end
            end
          end
        end
      end
    end else if (out_valid !== 1'b0) begin
      errors++;
      $display("bpu_sa_array_tb: out_valid_o is unknown at cycle %0d", cycle);
    end
    if (err_mode !== ((mode && !Int4) || (scaled && !Scale))) begin
      errors++;
      $display("bpu_sa_array_tb: err_mode_o = %b with mode_i = %b", err_mode, mode);
    end
  endtask

  // Choose the stimulus for the coming rising edge and model what that edge does.
  task automatic drive_and_model();
    int     slot;
    bit     in_fire;
    bit     out_fire;
    bit     in_final;
    longint p;

    // Input: a stalled k-step stays offered, unchanged, until it is accepted.
    if (!in_hold) begin
      in_valid = allow_new && (rand_below(100) < valid_pct);
      if (in_valid) begin
        for (int i = 0; i < Rows; i++) begin
          a_vals[i] = rand_int8();
          a_hi[i] = rand_int8();
          // In INT8 mode the high byte (Int4 builds) is junk the PEs must ignore.
          in_a[AW*i+:AW] = AW'({8'(a_hi[i]), 8'(a_vals[i])});
        end
        for (int j = 0; j < Cols; j++) begin
          if (Mode) begin
            b_vals[j]    = rand_int4();
            b_hi[j]      = rand_int4();
            in_b[8*j+:8] = {4'(b_hi[j]), 4'(b_vals[j])};
          end else begin
            b_vals[j]    = rand_int8();
            b_hi[j]      = 0;
            in_b[8*j+:8] = 8'(b_vals[j]);
          end
        end
        if (Scaled) begin
          // A block of 1 to BLOCK_STEPS transfers, cut short by the end of the tile.
          if (blk_pos == 0) begin
            blk_len = 1 + rand_below(BLOCK_STEPS);
            if (blk_len > tile_k - next_k) begin
              blk_len = tile_k - next_k;
            end
          end
          in_first  = (blk_pos == 0);
          in_last   = (blk_pos == blk_len - 1);
          in_slast  = in_last && (next_k == tile_k - 1);
          in_sfirst = in_last && blk_first && tile_restart;
          for (int i = 0; i < Rows; i++) begin
            sa_vals[i] = in_last ? rand_scale() : 16'(rand32());
            in_sa[16*i+:16] = sa_vals[i];
          end
          for (int j = 0; j < Cols; j++) begin
            sb_vals[j] = in_last ? rand_scale() : 16'(rand32());
            in_sb[16*j+:16] = sb_vals[j];
          end
        end else begin
          in_first  = (next_k == 0);
          in_last   = (next_k == tile_k - 1);
          in_sfirst = 1'(rand32());  // junk: ignored when unscaled
          in_slast  = 1'(rand32());
          in_sa     = {Rows{16'(rand32())}};
          in_sb     = {Cols{16'(rand32())}};
        end
      end
    end
    out_ready = (rand_below(100) < ready_pct);
    #1;  // in_ready_o follows the payload combinationally

    in_final = in_last && (!Scaled || in_slast);
    if (in_ready !== !(in_final && busy)) begin
      errors++;
      $display("bpu_sa_array_tb: in_ready_o = %b with a final k-step %b and the tile %s busy",
               in_ready, in_final, busy ? "" : "not");
    end
    in_fire  = in_valid && in_ready;
    out_fire = (out_valid === 1'b1) && out_ready && (head != tail);
    in_hold  = in_valid && !in_ready;
    if (in_hold) begin
      in_stalls++;
      if (count_stalls) begin
        stream_stalls++;
      end
    end
    if (out_valid === 1'b1 && !out_ready) begin
      out_stalls++;
    end

    if (in_fire) begin
      ksteps++;
      for (int i = 0; i < Rows; i++) begin
        for (int j = 0; j < Cols; j++) begin
          p = longint'(a_vals[i]) * longint'(b_vals[j]);
          if (Mode) begin
            p = p + longint'(a_hi[i]) * longint'(b_hi[j]);
          end
          if (in_first) begin
            acc[i][j] = p;
          end else begin
            acc[i][j] = acc[i][j] + p;
          end
        end
      end
      next_k++;
      if (Scaled && in_last) begin
        for (int i = 0; i < Rows; i++) begin
          for (int j = 0; j < Cols; j++) begin
            fx_block(i, j, acc[i][j], in_sfirst);
          end
        end
        if (in_sfirst) begin
          fx_known = 1'b1;
        end
        if (blk_first && !tile_restart) begin
          continued_tiles++;
        end
        blocks++;
        blk_pos   = 0;
        blk_first = 1'b0;
      end else if (Scaled) begin
        blk_pos++;
      end
      if (in_final) begin
        slot = tail % QUEUE_DEPTH;
        for (int i = 0; i < Rows; i++) begin
          for (int j = 0; j < Cols; j++) begin
            exp_val[slot][i][j] = Scaled ? fx_packed(i, j) : acc[i][j];
          end
        end
        if (inject_error && !injected && tiles_sent == 2) begin
          exp_val[slot][Rows-1][Cols-1] = exp_val[slot][Rows-1][Cols-1] + 1;
          injected = 1'b1;
        end
        exp_cycle[slot] = cycle;
        tail++;
        tiles_sent++;
        if (stream_k && tile_k == STREAM_K) begin
          count_stalls = 1'b1;  // the first stream tile may wait for an earlier drain
        end
        new_tile();
      end
    end

    if (out_fire) begin
      rows_checked++;
      if (row_ptr == Rows - 1) begin
        row_ptr = 0;
        head++;
        tiles_done++;
        if (count_stalls) begin
          stream_tiles_done++;
        end
      end else begin
        row_ptr++;
      end
    end

    if (in_fire && in_final) begin
      busy = 1'b1;
    end else if (out_fire && out_last) begin
      busy = 1'b0;
    end
  endtask

  task automatic step();
    @(negedge clk);
    cycle++;
    check_outputs();
    drive_and_model();
  endtask

  // Assert reset while a tile accumulates and the previous one drains; check that it
  // cancels all accepted work.
  task automatic reset_mid_work();
    int tries;
    tries = 0;
    while (!(head != tail && next_k > 0) && tries < ResetWaitCycles) begin
      step();
      tries++;
    end
    if (!(head != tail && next_k > 0)) begin
      $fatal(1, "active-reset precondition not reached: queued_tiles=%0d next_k=%0d tries=%0d",
             tail - head, next_k, tries);
    end

    // drive_and_model accounted for the coming rising edge; let it happen so the
    // hardware holds the same work as the model before reset.
    @(posedge clk);
    active_resets++;
    #2;  // between clock edges: an asynchronous assertion
    rst_n    = 1'b0;
    in_valid = 1'b0;
    #1;
    if (out_valid !== 1'b0 || in_ready !== 1'b1) begin
      errors++;
      $display("bpu_sa_array_tb: reset did not clear out_valid_o and set in_ready_o at once");
    end
    resets++;
    cancelled += tail - head;

    // Model: reset cancels every accepted k-step and finished tile; the next tile
    // must restart the scaled sums.
    head     = tail;
    row_ptr  = 0;
    busy     = 1'b0;
    in_hold  = 1'b0;
    fx_known = 1'b0;
    new_tile();

    repeat (3) begin
      @(negedge clk);
      cycle++;
      if (out_valid !== 1'b0) begin
        errors++;
        $display("bpu_sa_array_tb: out_valid_o rose while reset was held");
      end
    end
    rst_n = 1'b1;  // released on a falling edge, half a cycle before the next rising edge
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
    ksteps            = 0;
    tiles_sent        = 0;
    tiles_done        = 0;
    rows_checked      = 0;
    cancelled         = 0;
    in_stalls         = 0;
    stream_stalls     = 0;
    stream_tiles_done = 0;
    out_stalls        = 0;
    resets            = 0;
    active_resets     = 0;
    mode_checks       = 0;
    blocks            = 0;
    continued_tiles   = 0;
    fx_nans           = 0;
    fx_saturations    = 0;
    fx_known          = 1'b0;
    head              = 0;
    tail              = 0;
    row_ptr           = 0;
    busy              = 1'b0;
    in_hold           = 1'b0;
    cycle             = 0;
    stream_k          = 1'b0;
    count_stalls      = 1'b0;
    valid_pct         = 70;
    ready_pct         = 65;
    allow_new         = 1'b1;
    rng_state         = seed ^ 32'h9e37_79b9;
    if (rng_state == 0) begin
      rng_state = 1;
    end
    new_tile();

    rst_n     = 1'b0;
    mode      = Mode;
    scaled    = Scaled;
    in_valid  = 1'b0;
    in_a      = '0;
    in_b      = '0;
    in_first  = 1'b0;
    in_last   = 1'b0;
    in_sa     = '0;
    in_sb     = '0;
    in_sfirst = 1'b0;
    in_slast  = 1'b0;
    out_ready = 1'b0;
    repeat (2) begin
      @(negedge clk);
    end
    rst_n = 1'b1;

    // 1. traffic
    repeat (TrafficCycles) begin
      step();
    end

    // 2. stream: the tile in progress finishes, then StreamTiles tiles of STREAM_K
    valid_pct = 100;
    ready_pct = 100;
    stream_k  = 1'b1;
    while (stream_tiles_done < StreamTiles && cycle < TIMEOUT_CYCLES) begin
      step();
    end
    count_stalls = 1'b0;
    stream_k     = 1'b0;
    valid_pct    = 70;
    ready_pct    = 65;

    // 3. reset in the middle of active work
    reset_mid_work();

    // 4. traffic after reset
    repeat (TrafficCycles) begin
      step();
    end

    // 5. drain: finish the tile in progress, wait for every row, then the mode error
    while (next_k != 0 || in_hold) begin
      step();
    end
    allow_new = 1'b0;
    ready_pct = 100;
    repeat (LATENCY_CYCLES + Rows + 2) begin
      step();
    end
    if (head != tail) begin
      errors++;
      $display("bpu_sa_array_tb: %0d tiles never came out", tail - head);
    end
    @(negedge clk);
    mode = 1'b1;
    #1;
    if (err_mode !== (!Int4 || (Scaled && !Scale))) begin
      errors++;
      $display("bpu_sa_array_tb: err_mode_o = %b with mode_i = 1 and Int4 = %0d", err_mode, Int4);
    end
    mode_checks++;
    mode = Mode;

    if (errors != 0 || tiles_done != tiles_sent - cancelled || rows_checked != Rows * tiles_done
        || tiles_done < StreamTiles + 4 || stream_tiles_done < StreamTiles
        || stream_stalls != 0 || resets != 1 || active_resets != 1 || mode_checks != 1
        || in_stalls == 0 || (Scaled && (blocks <= tiles_sent || continued_tiles == 0))) begin
      status = "FAIL";
    end else begin
      status = "PASS";
    end
    $write("RESULT bpu_sa_array_tb rows=%0d cols=%0d accw=%0d int4=%0d mode=%0d scaled=%0d", Rows,
           Cols, AccW, Int4, Mode, Scaled);
    $write(" seed=%0d blocks=%0d continued=%0d fx_nans=%0d fx_saturations=%0d", seed, blocks,
           continued_tiles, fx_nans, fx_saturations);
    $write(" cycles=%0d ksteps=%0d tiles_sent=%0d tiles_checked=%0d rows_checked=%0d", cycle,
           ksteps, tiles_sent, tiles_done, rows_checked);
    $write(" cancelled=%0d in_stalls=%0d out_stalls=%0d stream_tiles=%0d stream_stalls=%0d",
           cancelled, in_stalls, out_stalls, stream_tiles_done, stream_stalls);
    $display(" resets=%0d active_resets=%0d errors=%0d status=%s", resets, active_resets, errors,
             status);
    if (status != "PASS") begin
      $fatal(1, "bpu_sa_array_tb: FAIL (%0d errors)", errors);
    end
    $finish;
  end

endmodule
