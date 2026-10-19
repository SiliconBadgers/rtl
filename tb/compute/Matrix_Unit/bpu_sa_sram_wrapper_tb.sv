// Self-checking testbench for bpu_sa_sram_wrapper against sram_arbiter_matrix_model
// (the arbiter's matrix port with an SRAM behind it): unscaled and block-scaled
// commands with INT8 or packed INT4 weights, at many lengths, illegal commands, and
// a reset in the middle of a command.
//
// One configuration per run; the regression runner
// (tb/compute/Matrix_Unit/run_tests.sh) runs several shapes, port widths, latencies,
// feature sets and seeds.
//
// Parameters: Rows, Cols, AccW, DataW, SizeW, BufRows, WriteAcks, Int4, Scale,
// BlockK (the wrapper); Latency, ReadyPct (the model: response latency, share of
// cycles the arbiter is ready); Commands (random commands per random phase), MaxK
// (cap on unscaled K), MaxBlocks (cap on random block counts) and Seed.
// Plusargs:
//   +seed=<n>       random seed (default: Seed)
//   +inject_error=1 corrupt one expected value on purpose; the run must FAIL
//
// Phases
//   1. directed  Unscaled K at the SRAM-row boundaries: 1, 2, 3, one below, at and
//                above the k-steps per SRAM row of A and of B, 2 * B + 1, and
//                K_LIMIT; then block-scaled K of 1 and 2 blocks and one block more
//                than a scale-table row holds. Each in INT8 and (Int4) INT4.
//   1b. chains   commands chained along K with cmd_clear_acc_i / cmd_write_output_i:
//                keep (unscaled), continue in INT4 with K = 1 (a mode change right
//                after a kept command), continue and write; with Scale, keep and
//                continue-and-write block-scaled.
//   1c. specials (Scale) the special block-scaled commands described below.
//   2. random    Commands commands of random mode, scaling, K and chaining: a kept
//                result is continued half the time, a third of the commands keep
//                their sums, and the last one writes.
//   3. illegal   K = 0; misaligned A, B and C; with Scale, K not a multiple of
//                BlockK and misaligned scale tables; a feature the build lacks;
//                continuing with nothing kept; with Scale, continuing kept unscaled
//                sums with a block-scaled command, after which a legal continuation
//                checks that the kept sums survived.
//   4. reset     a command keeps its sums; a long command is started and rst_n
//                asserted between clock edges while it is certainly still running,
//                held 3 cycles and released on a falling edge; the model drops
//                responses in flight with it. A continuation right after must be
//                illegal: reset discards kept sums.
//   5. random    Commands / 2 + 2 more commands after the reset; the last writes.
//   Operands go to random row-aligned places in their own regions and are filled
//   with fresh random data each command: int8 and int4 with extra weight on the
//   extremes; bf16 scales 2^-14 .. 2, with 5% zero and 5% negative. Unscaled
//   commands carry misaligned junk scale-table addresses, and commands that keep
//   their sums a junk C address; both must be ignored.
//   Commands follow each other with 0 to 2 idle cycles, so a new command is often
//   accepted in the cycle done_o pulses.
//
// Reference model: unscaled C is the exact integer sum, wrapped to AccW bits and
// sign-extended. Block-scaled C follows the numerics contract in
// bpu_sa_sram_wrapper and bpu_sa_pe, computed independently here: each block's
// contribution isum * sA * sB * 2^24 in double precision (exact: at most 35
// significant bits), rounded to nearest even, added into a saturating 48-bit
// fixed-point sum with sticky NaN and overflow flags; the result is NaN, +-infinity
// or the sum / 2^24 rounded once to FP32 by real_to_f32. Kept sums carry across
// commands: the exact integer sum continues (wrapped to AccW when compared), and the
// fixed-point sum continues in block order.
//
// Special block-scaled commands (with Scale): one with a NaN scale in
// row 0 (its C row must be NaN), and one in each mode with every operand at its
// negative limit and 2^16 scales (every element saturates: +infinity), and one with
// the B scales negated (every element saturates: -infinity).
//
// Checks: every C element in memory against the model, for every command that
// writes; no write at all from a command that keeps its sums; the number of reads
// and writes and their bytes for each command (exact sizes, all four streams); done_o
// once per command, with err_o only for an illegal one, one cycle after it is
// accepted, with no memory traffic; no SRAM response (read data or write
// acknowledgement) still in flight when done_o rises; busy_o from the cycle after
// acceptance until done_o; cmd_ready_o = !busy_o; err_o never without done_o; after
// reset, busy_o, done_o and matrix_req_valid_o low at once. The model checks the
// port protocol (stable stalled requests, alignment, sizes, reads only inside the
// command's operands and scale tables, writes only inside C). The run ends with
// $fatal(1, ...) on any error, on a count mismatch or on timeout, and prints one
// RESULT line for the runner.
//
// Scheduling: stimulus is driven and outputs are checked on the falling clock edge;
// the design and the model act on the rising edge.
module bpu_sa_sram_wrapper_tb;
  timeunit 1ns; timeprecision 1ps;

  parameter int Rows = 8;
  parameter int Cols = 8;
  parameter int AccW = 32;
  parameter int DataW = 4096;
  parameter int SizeW = 10;
  parameter int BufRows = 2;
  parameter bit WriteAcks = 1'b0;
  parameter bit Int4 = 1'b1;
  parameter bit Scale = 1'b1;
  parameter int BlockK = 16;
  parameter int Latency = 4;
  parameter int ReadyPct = 70;
  parameter int Commands = 16;
  parameter int MaxK = 600;
  parameter int MaxBlocks = 4;
  parameter int Seed = 1;

  localparam int ADDR_WIDTH = 32;
  localparam int K_WIDTH = 16;
  localparam int ROW_BYTES = DataW / 8;
  localparam int A_STEPS = ROW_BYTES / Rows;  // k-steps per SRAM row of A
  localparam int B_STEPS = ROW_BYTES / Cols;  // k-steps per SRAM row of INT8 B
  localparam int MAX_STEPS = (A_STEPS > B_STEPS) ? A_STEPS : B_STEPS;
  localparam int K_LIMIT = (2 * MAX_STEPS + 3 < MaxK) ? 2 * MAX_STEPS + 3 : MaxK;
  // Scale blocks per SRAM row of each table, and a block count that crosses a row.
  localparam int SA_BLOCKS = ROW_BYTES / (2 * Rows);
  localparam int SB_BLOCKS = ROW_BYTES / (2 * Cols);
  localparam int CROSS_BLOCKS = ((SA_BLOCKS > SB_BLOCKS) ? SA_BLOCKS : SB_BLOCKS) + 1;
  localparam int G_TOP = (CROSS_BLOCKS > MaxBlocks) ? CROSS_BLOCKS : MaxBlocks;
  localparam int K_MAX = (Scale && G_TOP * BlockK > K_LIMIT) ? G_TOP * BlockK : K_LIMIT;
  localparam int G_MAX = (K_MAX / BlockK > 0) ? K_MAX / BlockK : 1;
  localparam int C_BYTES = 4 * Rows * Cols;
  // Each region has 3 spare rows, so operands land at varying offsets.
  localparam int A_REGION = ((K_MAX * Rows + ROW_BYTES - 1) / ROW_BYTES + 3) * ROW_BYTES;
  localparam int B_REGION = ((K_MAX * Cols + ROW_BYTES - 1) / ROW_BYTES + 3) * ROW_BYTES;
  localparam int SA_REGION = ((2 * Rows * G_MAX + ROW_BYTES - 1) / ROW_BYTES + 3) * ROW_BYTES;
  localparam int SB_REGION = ((2 * Cols * G_MAX + ROW_BYTES - 1) / ROW_BYTES + 3) * ROW_BYTES;
  localparam int C_REGION = ((C_BYTES + ROW_BYTES - 1) / ROW_BYTES + 3) * ROW_BYTES;
  localparam int A_BASE = 0;
  localparam int B_BASE = A_BASE + A_REGION;
  localparam int SA_BASE = B_BASE + B_REGION;
  localparam int SB_BASE = SA_BASE + SA_REGION;
  localparam int C_BASE = SB_BASE + SB_REGION;
  localparam int MEM_BYTES = C_BASE + C_REGION;
  localparam int MODES = Int4 ? 2 : 1;
  localparam int DIRECTED_K = 11;
  localparam int DIRECTED = MODES * (DIRECTED_K + (Scale ? 3 : 0));
  localparam int CHAINS = 3 + (Scale ? 2 : 0);
  localparam int SPECIALS = Scale ? (Int4 ? 4 : 3) : 0;
  localparam int FX_W = 48;  // bpu_sa_pkg::FX_W
  localparam longint FX_MAX = (64'sd1 <<< (FX_W - 1)) - 1;
  localparam longint FX_MIN = -(64'sd1 <<< (FX_W - 1));
  // Directed, chains, specials, both random phases, the keep and continuation around
  // the kind mismatch, and the kept command before the reset.
  localparam int TOTAL_COMMANDS = DIRECTED + CHAINS + SPECIALS + Commands + Commands / 2 + 5;
  // The original seven or eight, nothing kept, the kind mismatch (Scale), and the
  // continuation after the reset.
  localparam int ILLEGAL = 4 + (Scale ? 3 : 1) + (Int4 ? 0 : 1) + 1 + (Scale ? 1 : 0) + 1;
  // Generous: every k-step waiting a full round trip, every request stalled.
  localparam int CMD_TIMEOUT = (K_MAX * (Latency + 4) + 40 * (Latency + 4) + 4 * (Rows + Cols)
      + 400) * 100 / ReadyPct;
  localparam int TIMEOUT_CYCLES = (TOTAL_COMMANDS + ILLEGAL + 10) * CMD_TIMEOUT;

  logic clk;
  logic rst_n;

  logic cmd_valid;
  logic cmd_ready;
  logic [ADDR_WIDTH-1:0] cmd_a_addr;
  logic [ADDR_WIDTH-1:0] cmd_b_addr;
  logic [ADDR_WIDTH-1:0] cmd_c_addr;
  logic [ADDR_WIDTH-1:0] cmd_sa_addr;
  logic [ADDR_WIDTH-1:0] cmd_sb_addr;
  logic [K_WIDTH-1:0] cmd_k;
  logic cmd_int4;
  logic cmd_scaled;
  logic cmd_clear_acc;
  logic cmd_write_output;
  logic busy;
  logic done;
  logic err;

  logic req_valid;
  logic req_ready;
  logic req_is_write;
  logic [SizeW-1:0] req_size;
  logic [ADDR_WIDTH-1:0] req_addr;
  logic [DataW-1:0] req_wdata;
  logic rsp_valid;
  logic [DataW-1:0] rsp_rdata;

  logic [3:0][ADDR_WIDTH-1:0] rd_lo;  // A, B, SA, SB windows
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

  // Reference model.
  int a_val[Rows][K_MAX];
  int b_val[K_MAX][Cols];
  logic [15:0] sa_val[Rows][G_MAX];
  logic [15:0] sb_val[G_MAX][Cols];
  logic [31:0] c_exp[Rows][Cols];
  longint acc_int[Rows][Cols];  // unscaled sums, exact, carried across kept commands
  longint fx_acc[Rows][Cols];  // block-scaled fixed-point sums (Q23.24), likewise
  bit fx_ovf[Rows][Cols];  // ... saturated
  bit fx_nan[Rows][Cols];  // ... met an inf or NaN scale
  int special;  // 0: random data; 1: a NaN scale in row 0; 2: extreme operands, 2^16 scales;
                // 3: as 2 with the B scales negated
  bit tb_kept;  // the DUT holds kept sums
  bit tb_kept_scaled;  // of a block-scaled command

  // Run control and statistics.
  int cycle;
  int seed;
  int unsigned rng_state;
  bit inject_error;
  int inject_arg;
  bit injected;
  int errors;
  int legal_done;
  int scaled_done;
  int int4_done;
  int illegal_done;
  int written_done;  // legal commands that wrote C
  int kept_done;  // legal commands that kept their sums
  int continued_done;  // legal commands that continued kept sums
  int continued_scaled;  // ... block-scaled ones
  int c_nans;  // NaN elements written
  int c_infs;  // infinite elements written
  int c_neg_infs;  // ... -infinity
  int resets;
  int ksteps;
  int busy_cycles;
  int c_checked;
  int k_limit_cycles8;  // directed K_LIMIT, INT8
  int k_limit_cycles4;  // directed K_LIMIT, INT4
  string status;

  bpu_sa_sram_wrapper #(
    .Rows     (Rows),
    .Cols     (Cols),
    .AccW     (AccW),
    .AddrW    (ADDR_WIDTH),
    .DataW    (DataW),
    .SizeW    (SizeW),
    .KW       (K_WIDTH),
    .BufRows  (BufRows),
    .WriteAcks(WriteAcks),
    .Int4     (Int4),
    .Scale    (Scale),
    .BlockK   (BlockK)
  ) u_dut (
    .clk_i                  (clk),
    .rst_ni                 (rst_n),
    .cmd_valid_i            (cmd_valid),
    .cmd_ready_o            (cmd_ready),
    .cmd_a_addr_i           (cmd_a_addr),
    .cmd_b_addr_i           (cmd_b_addr),
    .cmd_c_addr_i           (cmd_c_addr),
    .cmd_sa_addr_i          (cmd_sa_addr),
    .cmd_sb_addr_i          (cmd_sb_addr),
    .cmd_k_i                (cmd_k),
    .cmd_int4_i             (cmd_int4),
    .cmd_scaled_i           (cmd_scaled),
    .cmd_clear_acc_i        (cmd_clear_acc),
    .cmd_write_output_i     (cmd_write_output),
    .busy_o                 (busy),
    .done_o                 (done),
    .err_o                  (err),
    .matrix_req_valid_o     (req_valid),
    .matrix_req_ready_i     (req_ready),
    .matrix_req_is_write_o  (req_is_write),
    .matrix_req_size_bytes_o(req_size),
    .matrix_req_addr_o      (req_addr),
    .matrix_req_wdata_o     (req_wdata),
    .matrix_rsp_valid_i     (rsp_valid),
    .matrix_rsp_rdata_i     (rsp_rdata)
  );

  sram_arbiter_matrix_model #(
    .AddrW    (ADDR_WIDTH),
    .DataW    (DataW),
    .SizeW    (SizeW),
    .MemBytes (MEM_BYTES),
    .Latency  (Latency),
    .ReadyPct (ReadyPct),
    .WriteAcks(WriteAcks)
  ) u_sram (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .req_valid_i     (req_valid),
    .req_ready_o     (req_ready),
    .req_is_write_i  (req_is_write),
    .req_size_bytes_i(req_size),
    .req_addr_i      (req_addr),
    .req_wdata_i     (req_wdata),
    .rsp_valid_o     (rsp_valid),
    .rsp_rdata_o     (rsp_rdata),
    .rd_lo_i         (rd_lo),
    .rd_hi_i         (rd_hi),
    .c_lo_i          (c_lo),
    .c_hi_i          (c_hi),
    .reads_o         (reads),
    .writes_o        (writes),
    .read_bytes_o    (read_bytes),
    .write_bytes_o   (write_bytes),
    .errors_o        (model_errors),
    .stalls_o        (req_stalls),
    .in_flight_o     (in_flight)
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
    $fatal(1, "bpu_sa_sram_wrapper_tb: timeout after %0d cycles", TIMEOUT_CYCLES);
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

  // A random bf16 scale: 5% zero, 5% negative, magnitude 2^-14 .. 2.
  function automatic logic [15:0] rand_scale();
    int u;
    u = rand_below(20);
    if (u == 0) begin
      return 16'h0000;
    end
    return {(u == 1), 8'(127 - rand_below(15)), 7'(rand32())};
  endfunction

  // Double to IEEE binary32, round to nearest even. The result must be zero or a
  // normal number (checked).
  function automatic logic [31:0] real_to_f32(input real r);
    logic [63:0] d;
    logic [24:0] sig;
    logic [28:0] rest;
    int          e;
    d = $realtobits(r);
    if (d[62:0] == '0) begin
      return {d[63], 31'b0};
    end
    sig  = {2'b01, d[51:29]};
    rest = d[28:0];
    if (rest > 29'h1000_0000 || (rest == 29'h1000_0000 && sig[0])) begin
      sig = sig + 1'b1;
    end
    e = int'(d[62:52]) - 1023 + 127;
    if (sig[24]) begin
      sig = sig >> 1;
      e   = e + 1;
    end
    if (d[62:52] == '0 || e < 1 || e > 254) begin
      $fatal(1, "bpu_sa_sram_wrapper_tb: reference value %g is outside the tested range", r);
    end
    return {d[63], 8'(e), sig[22:0]};
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

  // bf16 as a real for the fixed-point contract: exact; exponent 0 (zero and
  // subnormals) counts as zero. Inf and NaN are handled before this is used.
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

  // One block into element (r, j)'s fixed-point sum: + round(isum * sx * sy * 2^24),
  // saturating, with sticky overflow and NaN flags; restart clears them first.
  task automatic fx_block(input int r, input int j, input longint isum, input logic [15:0] sx,
                          input logic [15:0] sy, input bit restart);
    real    x;
    longint c;
    longint t;
    if (restart) begin
      fx_acc[r][j] = 0;
      fx_ovf[r][j] = 1'b0;
      fx_nan[r][j] = 1'b0;
    end
    if (sx[14:7] == 8'hff || sy[14:7] == 8'hff) begin
      fx_nan[r][j] = 1'b1;
      return;
    end
    x = real'(isum) * bf16_value(sx) * bf16_value(sy) * pow2(24);
    if (x >= pow2(62) || x <= -pow2(62)) begin
      c = (x < 0.0) ? FX_MIN - 1 : FX_MAX + 1;  // out of range either way
    end else begin
      c = round_even(x);
    end
    if (c > FX_MAX || c < FX_MIN) begin
      fx_acc[r][j] = (x < 0.0) ? FX_MIN : FX_MAX;
      fx_ovf[r][j] = 1'b1;
      return;
    end
    t = fx_acc[r][j] + c;
    if (t > FX_MAX || t < FX_MIN) begin
      fx_acc[r][j] = (t > FX_MAX) ? FX_MAX : FX_MIN;
      fx_ovf[r][j] = 1'b1;
    end else begin
      fx_acc[r][j] = t;
    end
  endtask

  // Element (r, j)'s block-scaled C as binary32.
  function automatic logic [31:0] fx_result(input int r, input int j);
    if (fx_nan[r][j]) begin
      return 32'h7fc0_0000;
    end
    if (fx_ovf[r][j]) begin
      return {fx_acc[r][j] < 0, 8'hff, 23'h0};
    end
    return real_to_f32(real'(fx_acc[r][j]) / pow2(24));
  endfunction

  function automatic int clamp_k(input int k);
    if (k < 1) begin
      return 1;
    end
    if (k > K_LIMIT) begin
      return K_LIMIT;
    end
    return k;
  endfunction

  // Directed unscaled K number n: the SRAM-row boundaries.
  function automatic int directed_k(input int n);
    case (n)
      0: return 1;
      1: return clamp_k(2);
      2: return clamp_k(3);
      3: return clamp_k(A_STEPS - 1);
      4: return clamp_k(A_STEPS);
      5: return clamp_k(A_STEPS + 1);
      6: return clamp_k(B_STEPS - 1);
      7: return clamp_k(B_STEPS);
      8: return clamp_k(B_STEPS + 1);
      9: return clamp_k(2 * B_STEPS + 1);
      default: return K_LIMIT;
    endcase
  endfunction

  // A row-aligned offset that leaves room for bytes in a region of region bytes.
  function automatic int rand_offset(input int region, input int bytes);
    int spare_rows;
    spare_rows = (region - ((bytes + ROW_BYTES - 1) / ROW_BYTES) * ROW_BYTES) / ROW_BYTES;
    return rand_below(spare_rows + 1) * ROW_BYTES;
  endfunction

  function automatic int ceil_rows(input int bytes);
    return (bytes + ROW_BYTES - 1) / ROW_BYTES;
  endfunction

  function automatic int b_bytes(input int k, input bit int4);
    return int4 ? k * Cols / 2 : k * Cols;
  endfunction

  // One falling edge, with the checks that hold in every cycle.
  task automatic tick();
    @(negedge clk);
    cycle++;
    if (cmd_ready !== !busy) begin
      errors++;
      $display("bpu_sa_sram_wrapper_tb: cmd_ready_o = %b with busy_o = %b", cmd_ready, busy);
    end
    if (err === 1'b1 && done !== 1'b1) begin
      errors++;
      $display("bpu_sa_sram_wrapper_tb: err_o without done_o at cycle %0d", cycle);
    end
  endtask

  // Fill the operands with fresh data at random places, set the model's windows,
  // and compute the expected C: this command's sums, added to the kept ones unless
  // it clears.
  task automatic prepare(input int k, input bit int4, input bit scaled, input bit clear,
                         input bit write, output int a_addr, output int b_addr, output int sa_addr,
                         output int sb_addr, output int c_addr);
    int                g_count;
    int                n;
    logic   [     7:0] byte_val;
    longint            s;
    logic   [    63:0] s_bits;
    logic   [AccW-1:0] wrapped;

    g_count = scaled ? k / BlockK : 0;
    a_addr  = A_BASE + rand_offset(A_REGION, k * Rows);
    b_addr  = B_BASE + rand_offset(B_REGION, b_bytes(k, int4));
    sa_addr = SA_BASE + rand_offset(SA_REGION, 2 * Rows * g_count);
    sb_addr = SB_BASE + rand_offset(SB_REGION, 2 * Cols * g_count);
    // A command that keeps its sums ignores its C address: junk, often misaligned.
    c_addr  = write ? C_BASE + rand_offset(C_REGION, C_BYTES) : int'(rand32() % MEM_BYTES);

    for (int kk = 0; kk < k; kk++) begin
      for (int i = 0; i < Rows; i++) begin
        a_val[i][kk]                 = (special >= 2) ? -128 : rand_int8();
        u_sram.mem[a_addr+kk*Rows+i] = 8'(a_val[i][kk]);
      end
      for (int j = 0; j < Cols; j++) begin
        if (int4) begin
          b_val[kk][j] = (special >= 2) ? -8 : rand_int4();
          n            = kk * Cols + j;
          byte_val     = u_sram.mem[b_addr+n/2];
          if (n % 2 == 0) begin
            byte_val[3:0] = 4'(b_val[kk][j]);
          end else begin
            byte_val[7:4] = 4'(b_val[kk][j]);
          end
          u_sram.mem[b_addr+n/2] = byte_val;
        end else begin
          b_val[kk][j]                 = (special >= 2) ? -128 : rand_int8();
          u_sram.mem[b_addr+kk*Cols+j] = 8'(b_val[kk][j]);
        end
      end
    end
    for (int g = 0; g < g_count; g++) begin
      for (int i = 0; i < Rows; i++) begin
        sa_val[i][g]                       = (special == 1 && i == 0 && g == 0) ? 16'h7fc0
                                           : (special >= 2) ? 16'h4780 : rand_scale();
        u_sram.mem[sa_addr+2*(g*Rows+i)] = sa_val[i][g][7:0];
        u_sram.mem[sa_addr+2*(g*Rows+i)+1] = sa_val[i][g][15:8];
      end
      for (int j = 0; j < Cols; j++) begin
        sb_val[g][j] = (special == 3) ? 16'hc780 : (special == 2) ? 16'h4780 : rand_scale();
        u_sram.mem[sb_addr+2*(g*Cols+j)] = sb_val[g][j][7:0];
        u_sram.mem[sb_addr+2*(g*Cols+j)+1] = sb_val[g][j][15:8];
      end
    end

    for (int r = 0; r < Rows; r++) begin
      for (int j = 0; j < Cols; j++) begin
        if (scaled) begin
          for (int g = 0; g < g_count; g++) begin
            s = 0;
            for (int kk = g * BlockK; kk < (g + 1) * BlockK; kk++) begin
              s += longint'(a_val[r][kk]) * longint'(b_val[kk][j]);
            end
            fx_block(r, j, s, sa_val[r][g], sb_val[g][j], clear && g == 0);
          end
          c_exp[r][j] = fx_result(r, j);
        end else begin
          s = clear ? 0 : acc_int[r][j];
          for (int kk = 0; kk < k; kk++) begin
            s += longint'(a_val[r][kk]) * longint'(b_val[kk][j]);
          end
          acc_int[r][j] = s;
          s_bits        = s;
          wrapped       = s_bits[AccW-1:0];
          c_exp[r][j]   = 32'($signed(wrapped));
        end
      end
    end

    rd_lo[0] = ADDR_WIDTH'(a_addr);
    rd_hi[0] = ADDR_WIDTH'(a_addr + k * Rows);
    rd_lo[1] = ADDR_WIDTH'(b_addr);
    rd_hi[1] = ADDR_WIDTH'(b_addr + b_bytes(k, int4));
    rd_lo[2] = ADDR_WIDTH'(sa_addr);
    rd_hi[2] = ADDR_WIDTH'(sa_addr + 2 * Rows * g_count);
    rd_lo[3] = ADDR_WIDTH'(sb_addr);
    rd_hi[3] = ADDR_WIDTH'(sb_addr + 2 * Cols * g_count);
    // Keeping: an empty C window, so any write is a model error.
    c_lo     = write ? ADDR_WIDTH'(c_addr) : '0;
    c_hi     = write ? ADDR_WIDTH'(c_addr + C_BYTES) : '0;
  endtask

  // Offer a command from this falling edge until the wrapper accepts it.
  task automatic issue(input int k, input bit int4, input bit scaled, input bit clear,
                       input bit write, input int a_addr, input int b_addr, input int sa_addr,
                       input int sb_addr, input int c_addr);
    cmd_valid        = 1'b1;
    cmd_clear_acc    = clear;
    cmd_write_output = write;
    cmd_k            = K_WIDTH'(k);
    cmd_int4         = int4;
    cmd_scaled       = scaled;
    cmd_a_addr       = ADDR_WIDTH'(a_addr);
    cmd_b_addr       = ADDR_WIDTH'(b_addr);
    cmd_c_addr       = ADDR_WIDTH'(c_addr);
    cmd_sa_addr      = ADDR_WIDTH'(sa_addr);
    cmd_sb_addr      = ADDR_WIDTH'(sb_addr);
    while (cmd_ready !== 1'b1) begin
      tick();
    end
    // cmd_ready_o depends only on registers: the next rising edge accepts.
    tick();
    cmd_valid = 1'b0;
  endtask

  task automatic check_c(input int c_addr, input int cmd_index, input bit scaled);
    logic [31:0] got;
    for (int r = 0; r < Rows; r++) begin
      for (int j = 0; j < Cols; j++) begin
        for (int n = 0; n < 4; n++) begin
          got[8*n+:8] = u_sram.mem[c_addr+4*(r*Cols+j)+n];
        end
        c_checked++;
        if (scaled && got === 32'h7fc0_0000) begin
          c_nans++;
        end
        if (scaled && got[30:0] === 31'h7f80_0000) begin
          c_infs++;
          c_neg_infs += int'(got[31]);
        end
        if (got !== c_exp[r][j]) begin
          errors++;
          if (errors <= 10) begin
            if (scaled) begin
              $display("bpu_sa_sram_wrapper_tb: MISMATCH command %0d C[%0d][%0d]: got %h want %h",
                       cmd_index, r, j, got, c_exp[r][j]);
            end else begin
              $display("bpu_sa_sram_wrapper_tb: MISMATCH command %0d C[%0d][%0d]: got %0d want %0d",
                       cmd_index, r, j, $signed(got), $signed(c_exp[r][j]));
            end
          end
        end
      end
    end
  endtask

  // Run one legal command to completion and check it.
  task automatic run_legal(input int k, input bit int4, input bit scaled, input bit clear,
                           input bit write, input int cmd_index);
    int a_addr;
    int b_addr;
    int sa_addr;
    int sb_addr;
    int c_addr;
    int reads0;
    int writes0;
    int read_bytes0;
    int write_bytes0;
    int waited;
    int g_count;
    int want_reads;
    int want_read_bytes;
    int want_writes;
    int want_write_bytes;

    prepare(k, int4, scaled, clear, write, a_addr, b_addr, sa_addr, sb_addr, c_addr);
    if (!scaled) begin
      // Ignored without scaling: junk, often misaligned.
      sa_addr = int'(rand32() % MEM_BYTES);
      sb_addr = int'(rand32() % MEM_BYTES);
    end
    if (inject_error && !injected && cmd_index == 3) begin
      c_exp[0][0] = c_exp[0][0] ^ 32'h1;
      injected    = 1'b1;
    end
    reads0       = reads;
    writes0      = writes;
    read_bytes0  = read_bytes;
    write_bytes0 = write_bytes;

    issue(k, int4, scaled, clear, write, a_addr, b_addr, sa_addr, sb_addr, c_addr);
    waited = 1;
    while (done !== 1'b1) begin
      if (busy !== 1'b1) begin
        errors++;
        $display("bpu_sa_sram_wrapper_tb: busy_o low before done_o (command %0d)", cmd_index);
      end
      if (waited > CMD_TIMEOUT) begin
        $fatal(1, "bpu_sa_sram_wrapper_tb: command %0d (K = %0d) did not finish", cmd_index, k);
      end
      tick();
      waited++;
    end
    busy_cycles += waited;
    ksteps += k;
    $display("CMD %0d k=%0d int4=%0d scaled=%0d clear=%0d write=%0d cycles=%0d", cmd_index, k,
             int4, scaled, clear, write, waited);
    if (cmd_index < DIRECTED && k == K_LIMIT && !scaled) begin
      if (int4) begin
        k_limit_cycles4 = waited;
      end else begin
        k_limit_cycles8 = waited;
      end
    end
    if (err !== 1'b0 || busy !== 1'b0) begin
      errors++;
      $display("bpu_sa_sram_wrapper_tb: command %0d done with err_o = %b busy_o = %b", cmd_index,
               err, busy);
    end
    // Every response of the command, including write acknowledgements, has arrived.
    if (in_flight != 0 || rsp_valid !== 1'b0) begin
      errors++;
      $display("bpu_sa_sram_wrapper_tb: command %0d done with %0d responses still in flight",
               cmd_index, in_flight + int'(rsp_valid === 1'b1));
    end
    g_count = scaled ? k / BlockK : 0;
    want_reads = ceil_rows(k * Rows) + ceil_rows(b_bytes(k, int4)) + ceil_rows(2 * Rows * g_count) +
      ceil_rows(2 * Cols * g_count);
    want_read_bytes = k * Rows + b_bytes(k, int4) + 2 * (Rows + Cols) * g_count;
    if (reads - reads0 != want_reads || read_bytes - read_bytes0 != want_read_bytes) begin
      errors++;
      $display("bpu_sa_sram_wrapper_tb: command %0d: %0d reads, %0d bytes; expected %0d, %0d",
               cmd_index, reads - reads0, read_bytes - read_bytes0, want_reads, want_read_bytes);
    end
    // A command that keeps its sums writes nothing.
    want_writes      = write ? ceil_rows(C_BYTES) : 0;
    want_write_bytes = write ? C_BYTES : 0;
    if (writes - writes0 != want_writes || write_bytes - write_bytes0 != want_write_bytes) begin
      errors++;
      $display("bpu_sa_sram_wrapper_tb: command %0d: %0d writes, %0d bytes; expected %0d, %0d",
               cmd_index, writes - writes0, write_bytes - write_bytes0, want_writes,
               want_write_bytes);
    end
    if (write) begin
      check_c(c_addr, cmd_index, scaled);
      written_done++;
    end else begin
      kept_done++;
    end
    if (!clear) begin
      continued_done++;
      if (scaled) begin
        continued_scaled++;
      end
    end
    tb_kept        = !write;
    tb_kept_scaled = scaled;
    legal_done++;
    if (scaled) begin
      scaled_done++;
    end
    if (int4) begin
      int4_done++;
    end
  endtask

  // A random command. Kept sums are continued half the time, with the same kind as
  // they must be; a third of the commands keep their sums unless one must write.
  task automatic run_random(input int cmd_index, input bit must_write);
    bit int4;
    bit scaled;
    bit clear;
    bit write;
    int k;
    int4   = Int4 && (rand_below(2) == 1);
    clear  = !tb_kept || (rand_below(2) == 1);
    scaled = clear ? (Scale && (rand_below(2) == 1)) : tb_kept_scaled;
    write  = must_write || (rand_below(3) != 0);
    k      = scaled ? BlockK * (1 + rand_below(MaxBlocks)) : 1 + rand_below(K_LIMIT);
    run_legal(k, int4, scaled, clear, write, cmd_index);
  endtask

  // An illegal command: done_o and err_o one cycle after acceptance, no traffic.
  task automatic run_illegal(input int k, input bit int4, input bit scaled, input bit clear,
                             input bit write, input int a_addr, input int b_addr, input int sa_addr,
                             input int sb_addr, input int c_addr);
    int reads0;
    int writes0;
    reads0  = reads;
    writes0 = writes;
    issue(k, int4, scaled, clear, write, a_addr, b_addr, sa_addr, sb_addr, c_addr);
    if (done !== 1'b1 || err !== 1'b1 || busy !== 1'b0) begin
      errors++;
      $display(
        "bpu_sa_sram_wrapper_tb: illegal command K=%0d int4=%0d scaled=%0d clear=%0d %s%b%b%b", k,
        int4, scaled, clear, "done err busy = ", done, err, busy);
    end
    tick();
    if (done !== 1'b0 || err !== 1'b0) begin
      errors++;
      $display("bpu_sa_sram_wrapper_tb: done_o or err_o longer than one cycle");
    end
    repeat (Latency + 2) begin
      tick();
    end
    if (reads != reads0 || writes != writes0) begin
      errors++;
      $display("bpu_sa_sram_wrapper_tb: an illegal command touched memory");
    end
    illegal_done++;
  endtask

  // Start a long command and reset while it is certainly still running.
  task automatic reset_mid_command();
    int a_addr;
    int b_addr;
    int sa_addr;
    int sb_addr;
    int c_addr;
    int k;
    bit int4;
    int steps;
    int wait_cycles;

    int4  = Int4 && (rand_below(2) == 1);
    k     = Scale ? BlockK * MaxBlocks : K_LIMIT;
    steps = int4 ? (k + 1) / 2 : k;
    prepare(k, int4, Scale, 1'b1, 1'b1, a_addr, b_addr, sa_addr, sb_addr, c_addr);
    issue(k, int4, Scale, 1'b1, 1'b1, a_addr, b_addr, sa_addr, sb_addr, c_addr);
    // The array takes at most one step per cycle, so the command is still busy.
    wait_cycles = 1 + rand_below(steps);
    repeat (wait_cycles) begin
      tick();
    end
    if (busy !== 1'b1) begin
      errors++;
      $display("bpu_sa_sram_wrapper_tb: reset test: the command was no longer running");
    end

    #2;  // between clock edges: an asynchronous assertion
    rst_n = 1'b0;
    #1;
    if (busy !== 1'b0 || done !== 1'b0 || req_valid !== 1'b0 || cmd_ready !== 1'b1) begin
      errors++;
      $display("bpu_sa_sram_wrapper_tb: reset did not clear busy, done and the request at once");
    end
    resets++;
    repeat (3) begin
      @(negedge clk);
      cycle++;
      if (busy !== 1'b0 || done !== 1'b0 || req_valid !== 1'b0) begin
        errors++;
        $display("bpu_sa_sram_wrapper_tb: activity while reset was held");
      end
    end
    rst_n   = 1'b1;  // released on a falling edge, half a cycle before the next rising edge
    tb_kept = 1'b0;  // reset discards kept sums
  endtask

  task automatic idle_gap();
    int gap;
    gap = rand_below(3);
    repeat (gap) begin
      tick();
    end
  endtask

  initial begin : main
    int cmd_index;
    int misaligned;

    if (!$value$plusargs("seed=%d", seed)) begin
      seed = Seed;
    end
    if (!$value$plusargs("inject_error=%d", inject_arg)) begin
      inject_arg = 0;
    end
    inject_error     = (inject_arg != 0);
    injected         = 1'b0;
    errors           = 0;
    legal_done       = 0;
    scaled_done      = 0;
    int4_done        = 0;
    illegal_done     = 0;
    written_done     = 0;
    kept_done        = 0;
    continued_done   = 0;
    continued_scaled = 0;
    c_nans           = 0;
    c_infs           = 0;
    c_neg_infs       = 0;
    special          = 0;
    tb_kept          = 1'b0;
    tb_kept_scaled   = 1'b0;
    resets           = 0;
    ksteps           = 0;
    busy_cycles      = 0;
    c_checked        = 0;
    k_limit_cycles8  = 0;
    k_limit_cycles4  = 0;
    cycle            = 0;
    rng_state        = seed ^ 32'h9e37_79b9;
    if (rng_state == 0) begin
      rng_state = 1;
    end

    rst_n            = 1'b0;
    cmd_valid        = 1'b0;
    cmd_k            = '0;
    cmd_int4         = 1'b0;
    cmd_scaled       = 1'b0;
    cmd_clear_acc    = 1'b1;
    cmd_write_output = 1'b1;
    cmd_a_addr       = '0;
    cmd_b_addr       = '0;
    cmd_c_addr       = '0;
    cmd_sa_addr      = '0;
    cmd_sb_addr      = '0;
    rd_lo            = '0;
    rd_hi            = '0;
    c_lo             = '0;
    c_hi             = '0;
    // Random contents everywhere, so stale data is never zero by accident.
    for (int n = 0; n < MEM_BYTES; n++) begin
      u_sram.mem[n] = 8'(rand32());
    end
    repeat (2) begin
      @(negedge clk);
    end
    rst_n = 1'b1;
    tick();

    // 1. directed: SRAM-row boundaries, unscaled and block-scaled, each mode
    cmd_index = 0;
    for (int m = 0; m < MODES; m++) begin
      for (int n = 0; n < DIRECTED_K; n++) begin
        run_legal(directed_k(n), m == 1, 1'b0, 1'b1, 1'b1, cmd_index);
        cmd_index++;
        idle_gap();
      end
      if (Scale) begin
        run_legal(BlockK, m == 1, 1'b1, 1'b1, 1'b1, cmd_index);
        cmd_index++;
        idle_gap();
        run_legal(2 * BlockK, m == 1, 1'b1, 1'b1, 1'b1, cmd_index);
        cmd_index++;
        idle_gap();
        run_legal(CROSS_BLOCKS * BlockK, m == 1, 1'b1, 1'b1, 1'b1, cmd_index);
        cmd_index++;
        idle_gap();
      end
    end

    // 1b. chains along K: keep, continue in INT4 at K = 1 right after (a mode change
    // while the kept sums settle), continue and write; then block-scaled.
    run_legal(clamp_k(A_STEPS + 1), 1'b0, 1'b0, 1'b1, 1'b0, cmd_index);
    cmd_index++;
    run_legal(1, Int4, 1'b0, 1'b0, 1'b0, cmd_index);
    cmd_index++;
    idle_gap();
    run_legal(3, 1'b0, 1'b0, 1'b0, 1'b1, cmd_index);
    cmd_index++;
    idle_gap();
    if (Scale) begin
      run_legal(BlockK, 1'b0, 1'b1, 1'b1, 1'b0, cmd_index);
      cmd_index++;
      run_legal(2 * BlockK, Int4, 1'b1, 1'b0, 1'b1, cmd_index);
      cmd_index++;
      idle_gap();
    end

    // 1c. special block-scaled commands: a NaN scale, saturation in each mode, and
    // saturation to -infinity
    if (Scale) begin
      special = 1;
      run_legal(2 * BlockK, 1'b0, 1'b1, 1'b1, 1'b1, cmd_index);
      cmd_index++;
      special = 2;
      run_legal(BlockK, 1'b0, 1'b1, 1'b1, 1'b1, cmd_index);
      cmd_index++;
      if (Int4) begin
        run_legal(BlockK, 1'b1, 1'b1, 1'b1, 1'b1, cmd_index);
        cmd_index++;
      end
      special = 3;
      run_legal(BlockK, 1'b0, 1'b1, 1'b1, 1'b1, cmd_index);
      cmd_index++;
      special = 0;
      idle_gap();
    end

    // 2. random commands; the last one writes, so nothing is kept afterwards
    for (int n = 0; n < Commands; n++) begin
      run_random(cmd_index, n == Commands - 1);
      cmd_index++;
      idle_gap();
    end

    // 3. illegal commands
    misaligned = 1 + rand_below(ROW_BYTES - 1);
    run_illegal(0, 1'b0, 1'b0, 1'b1, 1'b1, A_BASE, B_BASE, SA_BASE, SB_BASE, C_BASE);
    run_illegal(1, 1'b0, 1'b0, 1'b1, 1'b1, A_BASE + misaligned, B_BASE, SA_BASE, SB_BASE, C_BASE);
    run_illegal(1, 1'b0, 1'b0, 1'b1, 1'b1, A_BASE, B_BASE + misaligned, SA_BASE, SB_BASE, C_BASE);
    run_illegal(1, 1'b0, 1'b0, 1'b1, 1'b1, A_BASE, B_BASE, SA_BASE, SB_BASE, C_BASE + misaligned);
    if (Scale) begin
      run_illegal(BlockK + 1, 1'b0, 1'b1, 1'b1, 1'b1, A_BASE, B_BASE, SA_BASE, SB_BASE, C_BASE);
      run_illegal(BlockK, 1'b0, 1'b1, 1'b1, 1'b1, A_BASE, B_BASE, SA_BASE + misaligned, SB_BASE,
                  C_BASE);
      run_illegal(BlockK, 1'b0, 1'b1, 1'b1, 1'b1, A_BASE, B_BASE, SA_BASE, SB_BASE + misaligned,
                  C_BASE);
    end else begin
      run_illegal(BlockK, 1'b0, 1'b1, 1'b1, 1'b1, A_BASE, B_BASE, SA_BASE, SB_BASE, C_BASE);
    end
    if (!Int4) begin
      run_illegal(2, 1'b1, 1'b0, 1'b1, 1'b1, A_BASE, B_BASE, SA_BASE, SB_BASE, C_BASE);
    end

    // Continuing with nothing kept.
    run_illegal(1, 1'b0, 1'b0, 1'b0, 1'b1, A_BASE, B_BASE, SA_BASE, SB_BASE, C_BASE);
    // Kept unscaled sums survive an illegal block-scaled continuation.
    run_legal(clamp_k(B_STEPS + 1), 1'b0, 1'b0, 1'b1, 1'b0, cmd_index);
    cmd_index++;
    if (Scale) begin
      run_illegal(BlockK, 1'b0, 1'b1, 1'b0, 1'b1, A_BASE, B_BASE, SA_BASE, SB_BASE, C_BASE);
    end
    run_legal(2, 1'b0, 1'b0, 1'b0, 1'b1, cmd_index);
    cmd_index++;

    // 4. reset in the middle of a command, with sums kept from before it; a
    // continuation afterwards must be illegal
    run_legal(3, Int4, 1'b0, 1'b1, 1'b0, cmd_index);
    cmd_index++;
    reset_mid_command();
    tick();
    run_illegal(1, 1'b0, 1'b0, 1'b0, 1'b1, A_BASE, B_BASE, SA_BASE, SB_BASE, C_BASE);

    // 5. random commands after the reset; the last one writes
    for (int n = 0; n < Commands / 2 + 2; n++) begin
      run_random(cmd_index, n == Commands / 2 + 1);
      cmd_index++;
      idle_gap();
    end
    repeat (Latency + 4) begin
      tick();
    end

    if (errors != 0 || model_errors != 0 || legal_done != TOTAL_COMMANDS
        || illegal_done != ILLEGAL || resets != 1 || c_checked != written_done * Rows * Cols
        || kept_done < 3 || continued_done < 3 || (Scale && continued_scaled < 1)
        || (Scale && (c_nans < Cols || c_infs - c_neg_infs < Rows * Cols
                      || c_neg_infs < Rows * Cols))
        || (Scale && scaled_done < 3) || (Int4 && int4_done < DIRECTED_K)
        || (ReadyPct < 100 && req_stalls == 0)) begin
      status = "FAIL";
    end else begin
      status = "PASS";
    end
    $write("RESULT bpu_sa_sram_wrapper_tb rows=%0d cols=%0d accw=%0d dataw=%0d buf=%0d", Rows,
           Cols, AccW, DataW, BufRows);
    $write(" int4=%0d scale=%0d acks=%0d latency=%0d ready_pct=%0d seed=%0d", Int4, Scale,
           WriteAcks, Latency, ReadyPct, seed);
    $write(" commands=%0d scaled=%0d int4_cmds=%0d illegal=%0d resets=%0d", legal_done,
           scaled_done, int4_done, illegal_done, resets);
    $write(" ksteps=%0d busy_cycles=%0d k_limit=%0d cycles_int8=%0d cycles_int4=%0d", ksteps,
           busy_cycles, K_LIMIT, k_limit_cycles8, k_limit_cycles4);
    $write(" reads=%0d writes=%0d req_stalls=%0d c_checked=%0d", reads, writes, req_stalls,
           c_checked);
    $write(" written=%0d kept=%0d continued=%0d continued_scaled=%0d", written_done, kept_done,
           continued_done, continued_scaled);
    $write(" c_nans=%0d c_infs=%0d c_neg_infs=%0d", c_nans, c_infs, c_neg_infs);
    $display(" model_errors=%0d errors=%0d status=%s", model_errors, errors, status);
    if (status != "PASS") begin
      $fatal(1, "bpu_sa_sram_wrapper_tb: FAIL (%0d errors, %0d model errors)", errors,
             model_errors);
    end
    $finish;
  end

endmodule
