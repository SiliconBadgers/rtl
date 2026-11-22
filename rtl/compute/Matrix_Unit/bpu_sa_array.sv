// Output-stationary systolic array: C = A * B with C held in the PEs. INT8 x INT8, or INT8
// activations x INT4 weights at two k-steps per cycle; unscaled (exact integer C) or
// block-scaled (each PE scales every block's integer sum by the block's bf16 scales into a
// fixed-point accumulator).
//
// PE(i,j) owns C[i][j]. A k-step brings one column of A in from the left and one row of B
// in from the top; A moves right and B down one PE per cycle, so K is unbounded and a sum
// never leaves its PE until the tile finishes. Accumulators are carry-save, with one
// carry-propagate add per column at the top edge as each finished row drains: no AccW
// adder in any PE, at the cost of twice the accumulator and shadow registers.
//
//              B[k][0]   B[k][1]   B[k][2]      B[k][j] enters column j, delayed j cycles
//                 |         |         |
//   A[0][k] -> PE(0,0) -> PE(0,1) -> PE(0,2)    A[i][k] enters row i, delayed i cycles
//                 |         |         |         (with the tile flags)
//   A[1][k] -> PE(1,0) -> PE(1,1) -> PE(1,2)
//
// A k-step sent on cycle t reaches PE(i,j) on cycle t + 1 + i + j.
//
// Modes change only while the array is idle (nothing accumulating, capturing or draining)
//   mode_i     0: INT8, one k-step per transfer. 1 (Int4 builds): INT4 pair, k-steps k
//              and k+1 per transfer; a "k-step" below is then one pair.
//   scaled_i   0: unscaled. 1 (Scale builds): block-scaled. in_first_i / in_last_i mark
//              each block; with in_last_i come the block's scales and the tile flags
//              in_sfirst_i (start the scaled sums from zero) and in_slast_i (drain).
//
// Input: ready/valid, one k-step per transfer
//   in_a_i     Rows lanes of AW bits (16 with Int4, else 8). INT8: A[i][k] in the low
//              byte. INT4 pair: A[i][k] low, A[i][k+1] high.
//   in_b_i     Cols lanes of 8 bits. INT8: B[k][j]. INT4 pair: B[k][j] in the low
//              nibble, B[k+1][j] in the high.
//   in_first_i, in_last_i  first and last k-step of a tile (block-scaled: of a block).
//   in_sa_i, in_sb_i, in_sfirst_i, in_slast_i  used only with in_last_i, block-scaled.
//   in_ready_o = !(final k-step && previous tile still capturing or draining). It depends
//   on payload bits, never on in_valid_i. One tile drains while the next accumulates, so
//   back-to-back tiles stream without stalls when K >= 2 * Rows + Cols (+ SCALE_PIPE
//   block-scaled) and the output keeps up.
//
// Output: ready/valid, one row per transfer, rows 0 to Rows-1 in order
//   out_row_o holds C[r][j] (AccW bits, signed) at [AccW*j +: AccW]; block-scaled,
//   out_fx_o holds {nan, overflow, value} (FX_PACK_W bits) at [FX_PACK_W*j +: FX_PACK_W].
//   out_row_idx_o is r; out_last_o marks row Rows-1. out_valid_o rises Rows + Cols - 1
//   edges (+ SCALE_PIPE block-scaled) after the edge that accepts the tile's final k-step.
//   The outputs depend only on registers. err_mode_o is high while a mode the build lacks
//   is selected; the array then computes INT8 or unscaled.
//
// Arithmetic: products are exact and sums wrap modulo 2^AccW, so a tile is exact while
// K < 2^(AccW-15) in INT8 mode. A block sum needs 16 + log2(BlockK) bits; the scaling is in
// bpu_sa_pe.
//
// Reset discards all accepted work: in_valid_i must be low during reset, and the first
// k-step after it must have in_first_i = 1. It clears the tile-flag pipeline and the tile
// and drain counters; accumulators, shadow registers and the A and B pipelines are data
// storage and are not reset.
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

  // PE grid. Each array holds every PE's outputs; inputs come from the neighbors.
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
