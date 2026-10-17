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
// Clock and reset
//   clk_i   Rising-edge clock. The only clock domain.
//   rst_ni  Active-low reset. Assertion may be asynchronous; deassertion must be
//           synchronous to clk_i and meet recovery and removal timing. The
//           instantiating design owns that guarantee; bpu_sa_array passes its
//           own reset through (see its header). Reset clears only first_o and
//           last_o. The accumulator, the shadow register and the A and B pipeline
//           registers are data storage and are not reset.
//
// Modes (mode_i; see bpu_sa_array for when it may change)
//   0  INT8:     a_i[7:0] x b_i[7:0], one signed int8 x int8 product per cycle.
//   1  INT4 pair (only with Int4 = 1): a_i[7:0] x b_i[3:0] + a_i[15:8] x b_i[7:4],
//      two signed int8 x int4 products per cycle (k-steps k and k+1).
// Both modes use the same eight partial-product rows and the same adder tree: the
// 8x8 multiplier splits into two 8x4 halves (the slides' "2x2 INT4" PE), so the
// INT4 mode costs only the row multiplexers and the wider A path.
//
// Arithmetic: products are exact; sums wrap modulo 2^AccW. Idle cycles carry
// A = B = 0, which adds nothing.
module bpu_sa_pe #(
  parameter int unsigned AccW = 32,   // Accumulator width in bits, >= 16.
  parameter bit          Int4 = 1'b1  // 1: build the INT4-pair mode (16-bit A path)
) (
  input logic clk_i,
  input logic rst_ni,
  input logic mode_i,

  // A and the tile flags, moving right (A is 16 bits with Int4, else 8)
  input  logic [(Int4 ? 16 : 8)-1:0] a_i,
  input  logic                       first_i,
  input  logic                       last_i,
  output logic [(Int4 ? 16 : 8)-1:0] a_o,
  output logic                       first_o,
  output logic                       last_o,

  // B, moving down
  input  logic [7:0] b_i,
  output logic [7:0] b_o,

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

  // Shadow register (carry-save): the finished C[i][j] while it drains.
  logic [AccW-1:0] shd_sum_q;
  logic [AccW-1:0] shd_carry_q;

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
  end

  // The array drains only after every PE has captured, and accepts the next
  // tile's last k-step only after the drain, so these never coincide. Both are
  // held at 0 during reset.
  always @(posedge clk_i) begin
    CaptureShiftExclusive_A :
    assert (!(last_i === 1'b1 && shift_i === 1'b1))
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
    if (last_i) begin
      shd_sum_q   <= s50;
      shd_carry_q <= c50;
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

endmodule
