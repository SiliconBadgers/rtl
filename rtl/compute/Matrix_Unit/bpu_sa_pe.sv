// One processing element (PE) of the output-stationary bpu_sa_array.
//
// PE(i,j) owns one element of the C tile, C[i][j]. Each cycle it multiplies the A
// value arriving from the left by the B value arriving from above and adds the
// product to its accumulator. The accumulator stays in carry-save form:
// separate sum and carry vectors whose value is sum + carry (mod 2^AccW), so no
// carry propagates inside the PE. A and the tile flags move right, and B moves
// down, one PE per cycle.
//
// Tile flags travel with A:
//   first_i  This k-step starts a new tile: the accumulator restarts from zero.
//   last_i   This k-step ends the tile: the finished sum (still carry-save) is
//            captured into the shadow register, so the next tile can start
//            accumulating at once while this one drains.
// Drain: shift_i, driven to every PE at once by the array, moves the shadow
// registers up one row. shd_sum_o / shd_carry_o feed the PE above; the array adds
// sum + carry at the top edge. The array never captures and shifts in the same
// cycle (CaptureShiftExclusive_A).
//
// Block-scaled mode (scaled_i = 1, Scale builds): the k-steps come in blocks, and
// first_i / last_i mark a block's first and last k-step. At each block end the
// block's exact integer sum isum is scaled into a second accumulator, acc_fx:
//   acc_fx = acc_fx + round(isum * sa * sb * 2^FX_FRAC)
// where sa_i (riding with A) and sb_i (riding with B) are the block's bf16 scales,
// sampled with last_i. Blocks with different scales are never added as raw
// integers. With last_i, sfirst_i restarts acc_fx from zero (the tile's first
// block) and slast_i copies the result into the shadow register for the drain (the
// tile's final block); both ride with A. The scaling is a pipeline of SCALE_PIPE
// cycles (decode and add, multiply, shift and round, accumulate), so it overlaps
// the next block; block ends may be any distance apart.
//   Numerics (bpu_sa_pkg; docs/compute/matrix_unit_io_scheme.md, Arithmetic):
//   - A scale with exponent 0 (zero or subnormal) counts as zero; exponent 255 (inf
//     or NaN) makes the element NaN.
//   - isum * ma * mb is exact; the shift to FX_FRAC fractional bits rounds to
//     nearest, ties to even.
//   - A contribution, or a sum, outside the FX_W-bit signed range saturates acc_fx
//     to that limit and sets the element's overflow flag. The NaN and overflow flags
//     are sticky until sfirst_i.
//   The drained shadow holds {nan, overflow, acc_fx}, zero-extended to 2 * AccW bits:
//   sum = the low AccW bits, carry = the high AccW bits.
//
// Clock and reset
//   clk_i   Rising-edge clock. The only clock domain.
//   rst_ni  Active-low reset. Assertion may be asynchronous; deassertion must be
//           synchronous to clk_i and meet recovery and removal timing. The
//           instantiating design owns that guarantee; bpu_sa_array passes its
//           own reset through (see its header). Reset clears the flag outputs and
//           the scaling pipeline's valid bits. The accumulators, the shadow register
//           and the data pipeline registers are data storage and are not reset.
//
// Modes (mode_i, scaled_i: static; see bpu_sa_array for when they may change)
//   mode_i = 0  INT8:     a_i[7:0] x b_i[7:0], one signed int8 x int8 product per
//               cycle.
//   mode_i = 1  INT4 pair (only with Int4 = 1): a_i[7:0] x b_i[3:0] + a_i[15:8] x
//               b_i[7:4], two signed int8 x int4 products per cycle (k-steps k and
//               k+1).
// Both modes use the same eight partial-product rows and the same adder tree: the
// 8x8 multiplier splits into two 8x4 halves (the slides' "2x2 INT4" PE), so the
// INT4 mode costs only the row multiplexers and the wider A path.
//
// Arithmetic: products are exact; integer sums wrap modulo 2^AccW. Idle cycles carry
// A = B = 0, which adds nothing.
module bpu_sa_pe
  import bpu_sa_pkg::*;
#(
  parameter int unsigned AccW  = 32,    // Accumulator width in bits, >= 16
  parameter bit          Int4  = 1'b1,  // 1: build the INT4-pair mode (16-bit A path)
  parameter bit          Scale = 1'b1,  // 1: build block scaling (AccW >= 25)
  parameter int unsigned BsumW = 20     // Bits of a block sum: 16 + log2(block k-steps)
) (
  input logic clk_i,
  input logic rst_ni,
  input logic mode_i,
  input logic scaled_i,

  // A, the tile flags and the row's block scale, moving right (A is 16 bits with
  // Int4, else 8)
  input  logic [(Int4 ? 16 : 8)-1:0] a_i,
  input  logic                       first_i,
  input  logic                       last_i,
  input  logic                       sfirst_i,
  input  logic                       slast_i,
  input  logic [               15:0] sa_i,
  output logic [(Int4 ? 16 : 8)-1:0] a_o,
  output logic                       first_o,
  output logic                       last_o,
  output logic                       sfirst_o,
  output logic                       slast_o,
  output logic [               15:0] sa_o,

  // B and the column's block scale, moving down
  input  logic [ 7:0] b_i,
  input  logic [15:0] sb_i,
  output logic [ 7:0] b_o,
  output logic [15:0] sb_o,

  // Drain: the shadow registers move up one row per shift
  input  logic            shift_i,
  input  logic [AccW-1:0] shd_sum_i,    // shadow of the PE below
  input  logic [AccW-1:0] shd_carry_i,
  output logic [AccW-1:0] shd_sum_o,    // this PE's shadow, to the PE above
  output logic [AccW-1:0] shd_carry_o
);

  // Accumulator (carry-save) and the value it continues from this cycle.
  logic [AccW-1:0] acc_sum_q;
  logic [AccW-1:0] acc_carry_q;
  logic [AccW-1:0] acc_sum_in;
  logic [AccW-1:0] acc_carry_in;

  // Shadow register (carry-save, or the packed scaled result): the finished C[i][j]
  // while it drains.
  logic [AccW-1:0] shd_sum_q;
  logic [AccW-1:0] shd_carry_q;
  logic capture_int;  // unscaled: the tile's last k-step
  logic capture_fx;  // block-scaled: the final block's scaled result
  logic [2*AccW-1:0] fx_pack;

  // Partial products: INT8 rows, INT4-pair rows, and the rows in use.
  logic int4_mode;
  logic [AccW-1:0] a0_ext;  // a_i[7:0], sign-extended
  logic [AccW-1:0] a1_ext;  // a_i[15:8], sign-extended (0 without Int4)
  logic [7:0][AccW-1:0] pp8;
  logic [7:0][AccW-1:0] pp4;
  logic [7:0][AccW-1:0] pp;

  // Wallace reduction: level L node n has sum sLn and carry cLn.
  logic [AccW-1:0] s10, c10, s11, c11, s12, c12;
  logic [AccW-1:0] s20, c20, s21, c21;
  logic [AccW-1:0] s30, c30, s40, c40, s50, c50;

  // 3:2 carry-save adder: one full adder per bit. x + y + z = sum + carry, with the
  // carry already shifted to its weight. Nothing ripples sideways, so the delay is
  // one full adder at any width. The carry out of the top bit falls off, which is
  // the intended modulo-2^AccW wrap.
  function automatic logic [2*AccW-1:0] csa(input logic [AccW-1:0] x, input logic [AccW-1:0] y,
                                            input logic [AccW-1:0] z);
    logic [AccW-1:0] s;
    logic [AccW-1:0] c;
    s = x ^ y ^ z;
    c = ((x & y) | (x & z) | (y & z)) << 1;
    return {c, s};
  endfunction

`ifndef SYNTHESIS
  initial begin
    if (AccW < 16) begin
      $fatal(1, "bpu_sa_pe: AccW = %0d is below the 16 bits one int8 product needs", AccW);
    end
    if (Scale && (2 * AccW < FX_PACK_W || AccW < BsumW)) begin
      $fatal(1, "bpu_sa_pe: Scale needs 2 * AccW >= %0d and AccW >= BsumW = %0d", FX_PACK_W, BsumW);
    end
  end

  // The array drains only after every PE has captured, and accepts the next
  // tile's final k-step only after the drain, so these never coincide. All are 0
  // during reset.
  always @(posedge clk_i) begin
    CaptureShiftExclusive_A :
    assert (!((capture_int === 1'b1 || capture_fx === 1'b1) && shift_i === 1'b1))
    else $error("bpu_sa_pe: capture and drain shift in the same cycle");
  end
`endif

  assign acc_sum_in   = first_i ? '0 : acc_sum_q;
  assign acc_carry_in = first_i ? '0 : acc_carry_q;
  assign a0_ext       = {{(AccW - 8) {a_i[7]}}, a_i[7:0]};

  if (Int4) begin : g_int4
    assign int4_mode = mode_i;
    assign a1_ext    = {{(AccW - 8) {a_i[15]}}, a_i[15:8]};
  end else begin : g_no_int4
    logic unused_mode;

    assign unused_mode = mode_i;
    assign int4_mode   = 1'b0;
    assign a1_ext      = '0;
  end

  // INT8: b = -b7*2^7 + sum_{i<7} b_i*2^i, so
  //   a*b = sum_{i<7} b_i*(a << i) + b7*(~(a << 7) + 1)   (mod 2^AccW).
  //   The +1 goes into bit 0 of row 1, which is always 0 there.
  for (genvar i = 0; i < 7; i++) begin : g_pp8
    if (i == 1) begin : g_plus_one
      assign pp8[i] = (b_i[i] ? (a0_ext << i) : '0) | AccW'(b_i[7]);
    end else begin : g_row
      assign pp8[i] = b_i[i] ? (a0_ext << i) : '0;
    end
  end
  assign pp8[7] = b_i[7] ? ~(a0_ext << 7) : '0;

  // INT4 pair: w = -w3*2^3 + sum_{i<3} w_i*2^i for each nibble, so rows 0-3 form
  // a0 * b_i[3:0] and rows 4-7 form a1 * b_i[7:4]. The two +1 terms go into bit 0
  // of rows 1 and 5, which is always 0 there.
  for (genvar i = 0; i < 3; i++) begin : g_pp4
    if (i == 1) begin : g_plus_one
      assign pp4[i]   = (b_i[i] ? (a0_ext << i) : '0) | AccW'(b_i[3]);
      assign pp4[i+4] = (b_i[i+4] ? (a1_ext << i) : '0) | AccW'(b_i[7]);
    end else begin : g_row
      assign pp4[i]   = b_i[i] ? (a0_ext << i) : '0;
      assign pp4[i+4] = b_i[i+4] ? (a1_ext << i) : '0;
    end
  end
  assign pp4[3] = b_i[3] ? ~(a0_ext << 3) : '0;
  assign pp4[7] = b_i[7] ? ~(a1_ext << 3) : '0;

  assign pp = int4_mode ? pp4 : pp8;

  // 10 rows (8 partial products + the accumulator's sum and carry) -> 2 rows.
  //   level 1: 10 -> 7   level 2: 7 -> 5   level 3: 5 -> 4   level 4: 4 -> 3   level 5: 3 -> 2
  assign {c10, s10} = csa(pp[0], pp[1], pp[2]);
  assign {c11, s11} = csa(pp[3], pp[4], pp[5]);
  assign {c12, s12} = csa(pp[6], pp[7], acc_sum_in);

  assign {c20, s20} = csa(s10, c10, s11);
  assign {c21, s21} = csa(c11, s12, c12);

  assign {c30, s30} = csa(s20, c20, s21);
  assign {c40, s40} = csa(s30, c30, c21);
  assign {c50, s50} = csa(s40, c40, acc_carry_in);

  always_ff @(posedge clk_i) begin
    acc_sum_q   <= s50;
    acc_carry_q <= c50;
    a_o         <= a_i;
    b_o         <= b_i;
  end

  always_ff @(posedge clk_i) begin
    if (capture_int) begin
      shd_sum_q   <= s50;
      shd_carry_q <= c50;
    end else if (capture_fx) begin
      {shd_carry_q, shd_sum_q} <= fx_pack;
    end else if (shift_i) begin
      shd_sum_q   <= shd_sum_i;
      shd_carry_q <= shd_carry_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      first_o <= 1'b0;
      last_o  <= 1'b0;
    end else begin
      first_o <= first_i;
      last_o  <= last_i;
    end
  end

  assign shd_sum_o   = shd_sum_q;
  assign shd_carry_o = shd_carry_q;

  // ---------------------------------------------------------------------------
  // Block scaling: block end -> decode and add -> multiply -> shift and round ->
  // accumulate
  // ---------------------------------------------------------------------------
  if (Scale) begin : g_scale
    // isum * ma * mb is below 2^(BsumW + 15) in magnitude; PROD_W also holds its
    // negation. SH_W holds ea + eb - SCALE_SHIFT_BIAS (-242 .. 264).
    localparam int unsigned PROD_W = BsumW + 17;
    localparam int unsigned SH_W = 10;
    localparam int unsigned WIDE_W = PROD_W + FX_W;
    localparam logic signed [FX_W-1:0] FX_MAX = {1'b0, {(FX_W - 1) {1'b1}}};
    localparam logic signed [FX_W-1:0] FX_MIN = {1'b1, {(FX_W - 1) {1'b0}}};

    // Stage 0: the block end, as the PE saw it.
    logic                     p0_valid_q;
    logic                     p0_first_q;
    logic                     p0_final_q;
    logic        [ BsumW-1:0] p0_sum_q;
    logic        [ BsumW-1:0] p0_carry_q;
    logic        [      15:0] p0_sa_q;
    logic        [      15:0] p0_sb_q;
    // Stage 1: isum resolved, the scales decoded and their mantissas multiplied.
    logic                     p1_valid_q;
    logic                     p1_first_q;
    logic                     p1_final_q;
    logic                     p1_zero_q;  // a scale is zero or subnormal
    logic                     p1_bad_q;  // a scale is inf or NaN
    logic                     p1_neg_q;  // sa * sb < 0
    logic signed [ BsumW-1:0] p1_isum_q;
    logic        [      15:0] p1_m_q;  // ma * mb
    logic        [       8:0] p1_esum_q;  // ea + eb
    // Stage 2: the exact signed product isum * ma * mb.
    logic                     p2_valid_q;
    logic                     p2_first_q;
    logic                     p2_final_q;
    logic                     p2_bad_q;
    logic signed [PROD_W-1:0] p2_prod_q;
    logic        [       8:0] p2_esum_q;
    // Stage 3: the rounded contribution in fixed point.
    logic                     p3_valid_q;
    logic                     p3_first_q;
    logic                     p3_final_q;
    logic                     p3_bad_q;
    logic                     p3_neg_q;  // the contribution's sign, for saturation
    logic signed [  FX_W-1:0] p3_contrib_q;
    logic                     p3_ovf_q;
    // The scaled accumulator and its sticky flags.
    logic signed [  FX_W-1:0] acc_fx_q;
    logic                     ovf_q;
    logic                     nan_q;

    // Stage 3 (combinational): shift into fixed point and round. Stage 4: saturate
    // and accumulate.
    logic signed [  SH_W-1:0] sh;
    logic        [  SH_W-1:0] rsh;  // -sh, for right shifts
    logic signed [WIDE_W-1:0] wide;
    logic signed [PROD_W-1:0] quot;
    logic        [PROD_W-1:0] rem;
    logic        [PROD_W-1:0] half;
    logic                     round_up;
    logic signed [  FX_W-1:0] contrib;
    logic                     contrib_ovf;
    logic signed [  FX_W-1:0] base;
    logic signed [    FX_W:0] total;
    logic                     add_ovf;
    logic signed [  FX_W-1:0] acc_next;
    logic                     ovf_next;
    logic                     nan_next;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        p0_valid_q <= 1'b0;
        p1_valid_q <= 1'b0;
        p2_valid_q <= 1'b0;
        p3_valid_q <= 1'b0;
        sfirst_o   <= 1'b0;
        slast_o    <= 1'b0;
      end else begin
        p0_valid_q <= scaled_i && last_i;
        p1_valid_q <= p0_valid_q;
        p2_valid_q <= p1_valid_q;
        p3_valid_q <= p2_valid_q;
        sfirst_o   <= sfirst_i;
        slast_o    <= slast_i;
      end
    end

    always_ff @(posedge clk_i) begin
      sa_o <= sa_i;
      sb_o <= sb_i;
      if (scaled_i && last_i) begin
        p0_first_q <= sfirst_i;
        p0_final_q <= slast_i;
        p0_sum_q   <= s50[BsumW-1:0];
        p0_carry_q <= c50[BsumW-1:0];
        p0_sa_q    <= sa_i;
        p0_sb_q    <= sb_i;
      end
      if (p0_valid_q) begin
        p1_first_q <= p0_first_q;
        p1_final_q <= p0_final_q;
        p1_zero_q  <= (p0_sa_q[14:7] == 8'h00) || (p0_sb_q[14:7] == 8'h00);
        p1_bad_q   <= (p0_sa_q[14:7] == 8'hff) || (p0_sb_q[14:7] == 8'hff);
        p1_neg_q   <= p0_sa_q[15] ^ p0_sb_q[15];
        p1_isum_q  <= $signed(p0_sum_q + p0_carry_q);
        p1_m_q     <= {1'b1, p0_sa_q[6:0]} * {1'b1, p0_sb_q[6:0]};
        p1_esum_q  <= 9'(p0_sa_q[14:7]) + 9'(p0_sb_q[14:7]);
      end
      if (p1_valid_q) begin
        p2_first_q <= p1_first_q;
        p2_final_q <= p1_final_q;
        p2_bad_q   <= p1_bad_q;
        p2_esum_q  <= p1_esum_q;
        if (p1_zero_q || p1_bad_q) begin
          p2_prod_q <= '0;
        end else if (p1_neg_q) begin
          p2_prod_q <= -(PROD_W'(p1_isum_q) * $signed(PROD_W'(p1_m_q)));
        end else begin
          p2_prod_q <= PROD_W'(p1_isum_q) * $signed(PROD_W'(p1_m_q));
        end
      end
      if (p2_valid_q) begin
        p3_first_q   <= p2_first_q;
        p3_final_q   <= p2_final_q;
        p3_bad_q     <= p2_bad_q;
        p3_neg_q     <= p2_prod_q[PROD_W-1];
        p3_contrib_q <= contrib;
        p3_ovf_q     <= contrib_ovf;
      end
      if (p3_valid_q) begin
        acc_fx_q <= acc_next;
        ovf_q    <= ovf_next;
        nan_q    <= nan_next;
      end
    end

    // contribution = round(prod * 2^sh), sh = ea + eb - SCALE_SHIFT_BIAS.
    assign sh = $signed(SH_W'(p2_esum_q)) - $signed(SH_W'(SCALE_SHIFT_BIAS));
    assign rsh = SH_W'(-sh);
    assign wide = WIDE_W'(p2_prod_q) <<< sh[5:0];
    // Right shift, rounding to nearest even: floor quotient, remainder, half an ulp.
    assign quot = p2_prod_q >>> rsh;
    assign rem = PROD_W'(p2_prod_q) & ((PROD_W'(1) << rsh) - 1'b1);
    assign half = PROD_W'(1) << (rsh - 1'b1);
    assign round_up = (rem > half) || (rem == half && quot[0]);

    always_comb begin
      contrib     = '0;
      contrib_ovf = 1'b0;
      if (!sh[SH_W-1]) begin
        // Left shift (exact): overflows unless the result fits FX_W signed bits.
        if (sh >= $signed(SH_W'(FX_W))) begin
          contrib_ovf = (p2_prod_q != '0);
        end else begin
          contrib_ovf = (wide[WIDE_W-1:FX_W-1] != '0) && (wide[WIDE_W-1:FX_W-1] != '1);
          contrib     = wide[FX_W-1:0];
        end
      end else if (rsh < SH_W'(PROD_W - 1)) begin
        contrib = FX_W'(quot) + FX_W'(round_up);
      end
      // Otherwise |prod| * 2^sh < 1/2: rounds to 0.
    end

    always_comb begin
      base    = p3_first_q ? '0 : acc_fx_q;
      total   = {base[FX_W-1], base} + {p3_contrib_q[FX_W-1], p3_contrib_q};
      add_ovf = (total[FX_W] != total[FX_W-1]);
      if (p3_ovf_q) begin
        acc_next = p3_neg_q ? FX_MIN : FX_MAX;
      end else if (add_ovf) begin
        acc_next = total[FX_W] ? FX_MIN : FX_MAX;
      end else begin
        acc_next = total[FX_W-1:0];
      end
      ovf_next = (!p3_first_q && ovf_q) || p3_ovf_q || add_ovf;
      nan_next = (!p3_first_q && nan_q) || p3_bad_q;
    end

    assign capture_fx = p3_valid_q && p3_final_q;
    assign fx_pack    = (2 * AccW)'({nan_next, ovf_next, acc_next});
  end else begin : g_no_scale
    logic unused_scale;

    assign unused_scale = ^{scaled_i, sfirst_i, slast_i, sa_i, sb_i};
    assign sfirst_o     = 1'b0;
    assign slast_o      = 1'b0;
    assign sa_o         = '0;
    assign sb_o         = '0;
    assign capture_fx   = 1'b0;
    assign fx_pack      = '0;
  end

  assign capture_int = last_i && !(Scale && scaled_i);

endmodule
