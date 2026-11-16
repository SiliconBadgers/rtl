// Output-stationary systolic array: C = A * B with C held in the PEs.
// INT8 x INT8, or INT8 activations x INT4 weights at two k-steps per cycle;
// unscaled (exact integer C) or block-scaled (each PE scales every block's integer
// sum by the block's bf16 scales into a fixed-point accumulator).
//
// PE(i,j) owns C[i][j]. Each k-step brings one column of A (Rows values, entering
// from the left, one per row) and one row of B (Cols values, entering from the top,
// one per column); every PE adds A[i][k] * B[k][j] to its accumulator. A moves
// right and B moves down one PE per cycle, so the reduction length K can be any
// length: the sum never leaves the PE until the tile is finished. Accumulators are
// carry-save (sum + carry vectors); the one carry-propagate add per column happens
// at the top edge, as each finished row drains out.
//
// Sources (one module per file; rtl/compute/Matrix_Unit/bpu_sa_array.f lists them):
//   bpu_sa_array.sv   this module: input skew, PE grid, tile control, drain
//   bpu_sa_pe.sv      one processing element
//   bpu_sa_delay.sv   a shift-register delay line
//   bpu_sa_pkg.sv     the block-scaled numerics constants
//
// ---------------------------------------------------------------------------------
// Geometry
//
//              B[k][0]   B[k][1]   B[k][2]      B[k][j] enters column j, delayed j cycles
//                 |         |         |
//   A[0][k] -> PE(0,0) -> PE(0,1) -> PE(0,2)    A[i][k] enters row i, delayed i cycles
//                 |         |         |         (with the tile flags)
//   A[1][k] -> PE(1,0) -> PE(1,1) -> PE(1,2)
//
//   The skews make A[i][k] and B[k][j] meet in PE(i,j) on the same cycle. The
//   k-step a caller sends on cycle t reaches PE(i,j) on cycle t + 1 + i + j.
//
// ---------------------------------------------------------------------------------
// Clock and reset
//
//   clk_i    Rising-edge clock. Every port is in this single clock domain; there
//            are no clock-domain crossings.
//   rst_ni   Active-low reset. Assertion may be asynchronous. Deassertion must be
//            synchronous to clk_i and meet recovery and removal timing for every
//            register in the array; the instantiating design owns that guarantee
//            (normally the system reset synchronizer that drives this reset). The
//            same reset goes to every bpu_sa_pe and bpu_sa_delay inside. The
//            producer must hold in_valid_i low while rst_ni is low.
//
//   Reset cancels all accepted work: a tile in progress or draining is discarded,
//   out_valid_o is low until a tile completed after reset drains, and the first
//   k-step after reset must have in_first_i = 1. Reset clears the control state
//   (tile-flag pipeline, tile and drain counters); accumulators, shadow registers
//   and the A and B pipelines are data storage and are not reset.
//
// ---------------------------------------------------------------------------------
// Interface (all widths in bits, all latencies in clk_i cycles)
//
//   Modes    scaled_i = 0: unscaled. A tile's sums are exact integers.
//            scaled_i = 1 (Scale = 1 builds only): block-scaled. The k-steps come
//            in blocks of at most BlockK; in_first_i / in_last_i mark a block's
//            first and last k-step, and with in_last_i come the block's scales
//            in_sa_i / in_sb_i and the tile flags in_sfirst_i (the tile's first
//            block: start the scaled sums from zero) and in_slast_i (its final
//            block: drain the scaled results). Each PE scales the block sum into
//            its fixed-point accumulator (bpu_sa_pe); a tile is complete only at a
//            block with in_slast_i. Like mode_i, scaled_i may change only while
//            the array is idle.
//            mode_i = 0 (INT8): one k-step per transfer.
//            mode_i = 1 (INT4 pair, Int4 = 1 builds only): two k-steps, k and k+1,
//            per transfer, with INT8 A and INT4 B. A tile's "k-step" below is
//            then one such pair. mode_i applies to every k-step inside the array,
//            so it may change only while the array is idle: no tile accumulating,
//            capturing or draining.
//   Input    in_valid_i / in_ready_o: ready/valid, one k-step per transfer.
//            in_a_i: Rows lanes of AW bits (AW = 16 with Int4, else 8); lane i is
//              in_a_i[AW*i +: AW]. INT8: A[i][k] (signed int8) in the lane's low
//              byte. INT4 pair: A[i][k] in the low byte, A[i][k+1] in the high.
//            in_b_i: Cols lanes of 8 bits; lane j is in_b_i[8*j +: 8]. INT8:
//              B[k][j] (signed int8). INT4 pair: B[k][j] (signed int4) in the low
//              nibble, B[k+1][j] in the high nibble.
//            in_first_i: first k-step of a tile, or (block-scaled) of a block: the
//              integer accumulators restart.
//            in_last_i: last k-step of a tile, or of a block. A tile with K = 1
//              sets both.
//            in_sa_i: Rows lanes of 16 bits, sA[i][g] (bf16) for row i; in_sb_i:
//              Cols lanes of 16 bits, sB[g][j] (bf16) for column j; in_sfirst_i,
//              in_slast_i: see Modes. All four count only with in_last_i in
//              block-scaled mode.
//            The tile's final k-step is its last k-step (unscaled) or the last
//            k-step of its in_slast_i block (block-scaled). in_ready_o is 1 except
//            for a final k-step while the previous tile is still capturing or
//            draining: in_ready_o = !(final k-step && tile busy). It depends
//            combinationally on payload bits, never on in_valid_i. One tile can
//            drain while the next accumulates, so back-to-back tiles stream
//            without stalls when K >= 2 * Rows + Cols (+ SCALE_PIPE block-scaled)
//            and the output keeps up; a shorter tile's final k-step waits for the
//            previous drain. Block ends inside a tile never wait.
//   Output   out_valid_o / out_ready_i: ready/valid, one row of the finished C
//            tile per transfer, rows 0 to Rows-1 in order. out_row_o holds
//            C[r][j] (signed, AccW bits) in bits [AccW*j +: AccW]; out_row_idx_o
//            is r; out_last_o marks row Rows-1. Block-scaled, out_fx_o holds the
//            packed result {nan, overflow, value} (FX_PACK_W bits) of C[r][j] in
//            bits [FX_PACK_W*j +: FX_PACK_W]. out_valid_o rises Rows + Cols - 1
//            clock edges (plus SCALE_PIPE block-scaled) after the edge that accepts
//            the tile's final k-step: the edge at which the last PE,
//            PE(Rows-1, Cols-1), captures it. out_row_o, out_fx_o and out_valid_o
//            depend only on registers.
//   Errors   err_mode_o is high while mode_i = 1 in a build without Int4 (the
//            array then computes INT8) or scaled_i = 1 in a build without Scale
//            (it then computes unscaled). There are no other error conditions.
//
// Arithmetic
//
//   Products are exact; sums wrap modulo 2^AccW. A tile's result is exact while
//   K * 16384 < 2^(AccW-1) in INT8 mode, i.e. K < 2^(AccW-15) (131,072 for the
//   default AccW = 32), and while K * 1024 < 2^(AccW-1) in INT4 mode (K counted in
//   single k-steps). Block-scaled: each block sum is exact (BlockK k-steps need
//   16 + log2(BlockK) bits, at most AccW); the scaling follows bpu_sa_pe.
//
// Knobs for the cost/benefit study:
//   * AccW: accumulator width; sets the longest exact K.
//   * Int4: the INT4-pair mode doubles MACs per cycle for INT4 weights at the cost
//     of a 16-bit A path (8 more flops per PE) and the partial-product muxes.
//   * Scale: block scaling in every PE (scale lanes, a 4-stage scaling pipeline,
//     a 48-bit accumulator); the largest per-PE cost, removable for unscaled-only
//     builds. BlockK sets the block-sum width.
//   * Carry-save accumulators and shadows (here) double those registers but keep
//     carry propagation out of every PE; the alternative resolves sum + carry in
//     each PE every cycle (one AccW adder per PE, half the registers).
//   * The drain shifts one row per cycle through the shadow registers; a wider or
//     column-parallel drain trades wiring for shorter tile-to-tile gaps.
// ---------------------------------------------------------------------------------
module bpu_sa_array
  import bpu_sa_pkg::*;
#(
  parameter int unsigned Rows   = 8,     // rows of the C tile = A values per k-step, >= 1
  parameter int unsigned Cols   = 8,     // columns of the C tile = B values per k-step, >= 1
  parameter int unsigned AccW   = 32,    // accumulator width in bits, >= 16 (>= 25 with Scale)
  parameter bit          Int4   = 1'b1,  // 1: build the INT4-pair mode
  parameter bit          Scale  = 1'b1,  // 1: build the block-scaled mode
  parameter int unsigned BlockK = 16     // k-steps per scale block at most (a power of two)
) (
  input logic clk_i,
  input logic rst_ni,

  input  logic mode_i,     // 0: INT8; 1: INT4 pair (Int4 builds)
  input  logic scaled_i,   // 0: unscaled; 1: block-scaled (Scale builds)
  output logic err_mode_o,

  // Input: one k-step per transfer
  input  logic                            in_valid_i,
  output logic                            in_ready_o,
  input  logic [Rows*(Int4 ? 16 : 8)-1:0] in_a_i,
  input  logic [              Cols*8-1:0] in_b_i,
  input  logic                            in_first_i,
  input  logic                            in_last_i,
  input  logic [             Rows*16-1:0] in_sa_i,
  input  logic [             Cols*16-1:0] in_sb_i,
  input  logic                            in_sfirst_i,
  input  logic                            in_slast_i,

  // Output: one row of the finished C tile per transfer
  output logic                                     out_valid_o,
  input  logic                                     out_ready_i,
  output logic [                    Cols*AccW-1:0] out_row_o,
  output logic [               Cols*FX_PACK_W-1:0] out_fx_o,
  output logic [$clog2((Rows > 1) ? Rows : 2)-1:0] out_row_idx_o,
  output logic                                     out_last_o
);

  // Edges from the one that accepts a tile's last k-step to the one at which the
  // last PE, PE(Rows-1, Cols-1), captures it (it arrives 1 + Rows-1 + Cols-1 cycles
  // later). The drain starts at that edge and first shifts at the next.
  localparam int unsigned CAPTURE_CYCLES = Rows + Cols - 1;
  localparam int unsigned ROW_IDX_WIDTH = $clog2((Rows > 1) ? Rows : 2);
  localparam int unsigned ROW_COUNT_WIDTH = $clog2(Rows + 1);
  localparam int unsigned A_WIDTH = Int4 ? 16 : 8;  // bits per A lane
  localparam int unsigned BSUM_WIDTH = 16 + $clog2(BlockK);  // one block sum, signed

  // Tile control.
  logic in_fire;
  logic in_final;  // a tile's final k-step
  logic last_fire;
  logic captured_int;
  logic captured_fx;
  logic tile_busy_q;  // a tile's last k-step was accepted and it has not fully drained
  logic captured;  // pulse: every PE has captured the tile
  logic [ROW_COUNT_WIDTH-1:0] drain_left_q;  // rows of the finished tile still to send
  logic shift;  // one row drains this cycle

  // Input registers and skews.
  logic [Rows-1:0][A_WIDTH-1:0] a_q;
  logic [Cols-1:0][7:0] b_q;
  logic [3:0] flags_q;  // {first, last, sfirst, slast}
  logic [Rows-1:0][15:0] sa_q;
  logic [Cols-1:0][15:0] sb_q;
  logic [Rows-1:0][A_WIDTH-1:0] left_a;
  logic [Rows-1:0][3:0] left_flags;
  logic [Rows-1:0][15:0] left_sa;
  logic [Cols-1:0][7:0] top_b;
  logic [Cols-1:0][15:0] top_sb;

  // PE grid. Each array holds every PE's outputs; inputs come from the neighbours.
  logic [Rows-1:0][Cols-1:0][A_WIDTH-1:0] a_rt;  // going right: A values
  logic [Rows-1:0][Cols-1:0] first_rt;  // going right: first flags
  logic [Rows-1:0][Cols-1:0] last_rt;  // going right: last flags
  logic [Rows-1:0][Cols-1:0] sfirst_rt;  // going right: scaled-tile flags
  logic [Rows-1:0][Cols-1:0] slast_rt;
  logic [Rows-1:0][Cols-1:0][15:0] sa_rt;  // going right: row scales
  logic [Rows-1:0][Cols-1:0][7:0] b_dn;  // going down: B values
  logic [Rows-1:0][Cols-1:0][15:0] sb_dn;  // going down: column scales
  logic [Rows-1:0][Cols-1:0][AccW-1:0] shd_sum;  // going up: shadow sums
  logic [Rows-1:0][Cols-1:0][AccW-1:0] shd_carry;  // going up: shadow carries

  // The right column's A and flags and the bottom row's B have no consumer.
  logic unused_edges;

`ifndef SYNTHESIS
  initial begin
    if (Rows < 1 || Cols < 1) begin
      $fatal(1, "bpu_sa_array: Rows and Cols must be at least 1");
    end
    if (AccW < 16) begin
      $fatal(1, "bpu_sa_array: AccW = %0d is below 16", AccW);
    end
    if (Scale && ((BlockK & (BlockK - 1)) != 0 || 2 * AccW < FX_PACK_W || AccW < BSUM_WIDTH)) begin
      $fatal(1, "bpu_sa_array: Scale needs BlockK a power of two and AccW >= %0d", BSUM_WIDTH);
    end
  end
`endif

  assign err_mode_o = (mode_i && !Int4) || (scaled_i && !Scale);

  // ---------------------------------------------------------------------------
  // Tile control: accept k-steps, wait for the capture, drain one row per cycle
  // ---------------------------------------------------------------------------
  assign in_final = in_last_i && (!(Scale && scaled_i) || in_slast_i);
  assign in_ready_o = !(in_final && tile_busy_q);
  assign in_fire = in_valid_i && in_ready_o;
  assign last_fire = in_fire && in_final;
  assign out_valid_o = (drain_left_q != '0);
  assign out_last_o = (drain_left_q == ROW_COUNT_WIDTH'(1));
  assign out_row_idx_o = ROW_IDX_WIDTH'(ROW_COUNT_WIDTH'(Rows) - drain_left_q);
  assign shift = out_valid_o && out_ready_i;

  // A block-scaled tile is captured SCALE_PIPE cycles later: after the scaling.
  bpu_sa_delay #(
    .Width(1),
    .Depth(CAPTURE_CYCLES),
    .Reset(1'b1)
  ) u_capture (
    .clk_i,
    .rst_ni,
    .d_i(last_fire && !(Scale && scaled_i)),
    .q_o(captured_int)
  );

  if (Scale) begin : g_capture_fx
    bpu_sa_delay #(
      .Width(1),
      .Depth(CAPTURE_CYCLES + SCALE_PIPE),
      .Reset(1'b1)
    ) u_capture_fx (
      .clk_i,
      .rst_ni,
      .d_i(last_fire && scaled_i),
      .q_o(captured_fx)
    );
  end else begin : g_no_capture_fx
    assign captured_fx = 1'b0;
  end

  assign captured = captured_int || captured_fx;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      tile_busy_q  <= 1'b0;
      drain_left_q <= '0;
    end else begin
      if (last_fire) begin
        tile_busy_q <= 1'b1;
      end else if (shift && out_last_o) begin
        tile_busy_q <= 1'b0;
      end
      if (captured) begin
        drain_left_q <= ROW_COUNT_WIDTH'(Rows);
      end else if (shift) begin
        drain_left_q <= drain_left_q - 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Input registers and skew: row i of A and column j of B are delayed i and j
  // cycles. Idle cycles carry zeros, which add nothing.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    a_q  <= in_fire ? in_a_i : '0;
    b_q  <= in_fire ? in_b_i : '0;
    sa_q <= in_sa_i;
    sb_q <= in_sb_i;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      flags_q <= '0;
    end else begin
      flags_q <= in_fire ? {in_first_i, in_last_i, in_sfirst_i, in_slast_i} : 4'b0000;
    end
  end

  for (genvar i = 0; i < Rows; i++) begin : g_row_skew
    bpu_sa_delay #(
      .Width(A_WIDTH),
      .Depth(i)
    ) u_a (
      .clk_i,
      .rst_ni,
      .d_i(a_q[i]),
      .q_o(left_a[i])
    );
    bpu_sa_delay #(
      .Width(4),
      .Depth(i),
      .Reset(1'b1)
    ) u_flags (
      .clk_i,
      .rst_ni,
      .d_i(flags_q),
      .q_o(left_flags[i])
    );
    bpu_sa_delay #(
      .Width(16),
      .Depth(i)
    ) u_sa (
      .clk_i,
      .rst_ni,
      .d_i(sa_q[i]),
      .q_o(left_sa[i])
    );
  end

  for (genvar j = 0; j < Cols; j++) begin : g_col_skew
    bpu_sa_delay #(
      .Width(8),
      .Depth(j)
    ) u_b (
      .clk_i,
      .rst_ni,
      .d_i(b_q[j]),
      .q_o(top_b[j])
    );
    bpu_sa_delay #(
      .Width(16),
      .Depth(j)
    ) u_sb (
      .clk_i,
      .rst_ni,
      .d_i(sb_q[j]),
      .q_o(top_sb[j])
    );
  end

  // ---------------------------------------------------------------------------
  // PE grid
  // ---------------------------------------------------------------------------
  for (genvar i = 0; i < Rows; i++) begin : g_row
    for (genvar j = 0; j < Cols; j++) begin : g_col
      logic [A_WIDTH-1:0] a_in;
      logic first_in;
      logic last_in;
      logic sfirst_in;
      logic slast_in;
      logic [15:0] sa_in;
      logic [7:0] b_in;
      logic [15:0] sb_in;
      logic [AccW-1:0] shd_sum_in;
      logic [AccW-1:0] shd_carry_in;

      if (j == 0) begin : g_left
        assign a_in      = left_a[i];
        assign first_in  = left_flags[i][3];
        assign last_in   = left_flags[i][2];
        assign sfirst_in = left_flags[i][1];
        assign slast_in  = left_flags[i][0];
        assign sa_in     = left_sa[i];
      end else begin : g_right
        assign a_in      = a_rt[i][j-1];
        assign first_in  = first_rt[i][j-1];
        assign last_in   = last_rt[i][j-1];
        assign sfirst_in = sfirst_rt[i][j-1];
        assign slast_in  = slast_rt[i][j-1];
        assign sa_in     = sa_rt[i][j-1];
      end

      if (i == 0) begin : g_top
        assign b_in  = top_b[j];
        assign sb_in = top_sb[j];
      end else begin : g_below
        assign b_in  = b_dn[i-1][j];
        assign sb_in = sb_dn[i-1][j];
      end

      if (i == Rows - 1) begin : g_bottom
        assign shd_sum_in   = '0;
        assign shd_carry_in = '0;
      end else begin : g_above_bottom
        assign shd_sum_in   = shd_sum[i+1][j];
        assign shd_carry_in = shd_carry[i+1][j];
      end

      bpu_sa_pe #(
        .AccW (AccW),
        .Int4 (Int4),
        .Scale(Scale),
        .BsumW(BSUM_WIDTH)
      ) u_pe (
        .clk_i,
        .rst_ni,
        .mode_i,
        .scaled_i,
        .a_i        (a_in),
        .first_i    (first_in),
        .last_i     (last_in),
        .sfirst_i   (sfirst_in),
        .slast_i    (slast_in),
        .sa_i       (sa_in),
        .a_o        (a_rt[i][j]),
        .first_o    (first_rt[i][j]),
        .last_o     (last_rt[i][j]),
        .sfirst_o   (sfirst_rt[i][j]),
        .slast_o    (slast_rt[i][j]),
        .sa_o       (sa_rt[i][j]),
        .b_i        (b_in),
        .sb_i       (sb_in),
        .b_o        (b_dn[i][j]),
        .sb_o       (sb_dn[i][j]),
        .shift_i    (shift),
        .shd_sum_i  (shd_sum_in),
        .shd_carry_i(shd_carry_in),
        .shd_sum_o  (shd_sum[i][j]),
        .shd_carry_o(shd_carry[i][j])
      );
    end
  end

  for (genvar i = 0; i < Rows; i++) begin : g_unused_right
    logic unused_row;
    assign unused_row = ^{a_rt[i][Cols-1], first_rt[i][Cols-1], last_rt[i][Cols-1],
                          sfirst_rt[i][Cols-1], slast_rt[i][Cols-1], sa_rt[i][Cols-1]};
  end
  assign unused_edges = ^{b_dn[Rows-1], sb_dn[Rows-1]};

  // ---------------------------------------------------------------------------
  // Top edge: resolve sum + carry for the row at the top of the drain, or pass the
  // packed block-scaled result through
  // ---------------------------------------------------------------------------
  for (genvar j = 0; j < Cols; j++) begin : g_top_edge
    assign out_row_o[AccW*j+:AccW] = shd_sum[0][j] + shd_carry[0][j];
    if (Scale) begin : g_fx
      logic [2*AccW-1:0] shd_bits;

      assign shd_bits                         = {shd_carry[0][j], shd_sum[0][j]};
      assign out_fx_o[FX_PACK_W*j+:FX_PACK_W] = shd_bits[FX_PACK_W-1:0];
      if (2 * AccW > FX_PACK_W) begin : g_spare
        logic unused_spare;

        assign unused_spare = ^shd_bits[2*AccW-1:FX_PACK_W];
      end
    end else begin : g_no_fx
      assign out_fx_o[FX_PACK_W*j+:FX_PACK_W] = '0;
    end
  end

endmodule
