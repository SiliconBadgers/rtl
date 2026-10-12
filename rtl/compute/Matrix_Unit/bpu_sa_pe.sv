// One processing element (PE) of bpu_sa_array.
//
// Holds one int8 element of the A tile in two registers: a_shadow_q, where the
// next tile is loaded through a shift chain down each array column, and
// a_active_q, the element of the tile in use. Each cycle it multiplies its A
// value by the int8 B value arriving from above and adds the product to the
// partial sum arriving from the left. The partial sum stays in carry-save form:
// separate sum and carry vectors whose value is sum + carry (mod 2^AccW), so no
// carry propagates inside the PE.
//
// Clock and reset
//   clk_i   Rising-edge clock. The only clock domain.
//   rst_ni  Active-low reset. Assertion may be asynchronous; deassertion must be
//           synchronous to clk_i and meet recovery and removal timing. The
//           instantiating design owns that guarantee; bpu_sa_array passes its
//           own reset through (see its header). Reset clears only swap_o. The A
//           registers, b_o and the partial-sum outputs are data storage and are
//           not reset.
//
// Ports (every output is registered: one cycle per PE-to-PE hop)
//   load_i, load_a_i    load_i = 1: a_shadow_q <= load_a_i. The array drives load_i
//                       to every PE at once, so the shadow registers shift down a
//                       row per load.
//   load_a_o            a_shadow_q, to the load_a_i of the PE below.
//   b_i, b_o            int8 B value; b_o = b_i one cycle later.
//   swap_i, swap_o      Tile switch. swap_i = 1 makes this cycle's B use
//                       a_shadow_q and copies it into a_active_q. swap_o = swap_i
//                       one cycle later.
//   sum_i, carry_i      Carry-save partial sum from the PE on the left.
//   sum_o, carry_o      sum_i + carry_i + A * b_i, one cycle later, carry-save.
//   mode_i              Reserved for an int4 mode (see bpu_sa_array); ignored.
//
// Arithmetic: signed int8 x signed int8 products are exact; sums wrap modulo
// 2^AccW.
module bpu_sa_pe #(
  parameter int unsigned AccW = 32  // Partial-sum width in bits, >= 16.
) (
  input logic clk_i,
  input logic rst_ni,
  input logic mode_i,

  input  logic       load_i,
  input  logic [7:0] load_a_i,
  output logic [7:0] load_a_o,

  input  logic [7:0] b_i,
  input  logic       swap_i,
  output logic [7:0] b_o,
  output logic       swap_o,

  input  logic [AccW-1:0] sum_i,
  input  logic [AccW-1:0] carry_i,
  output logic [AccW-1:0] sum_o,
  output logic [AccW-1:0] carry_o
);

  // A registers.
  logic [7:0] a_shadow_q;
  logic [7:0] a_active_q;
  logic [7:0] a_use;

  // Partial products of a_use * b_i.
  logic [AccW-1:0] a_ext;
  logic [7:0][AccW-1:0] pp;

  // Wallace reduction: level L node n has sum sLn and carry cLn.
  logic [AccW-1:0] s10, c10, s11, c11, s12, c12;
  logic [AccW-1:0] s20, c20, s21, c21;
  logic [AccW-1:0] s30, c30, s40, c40, s50, c50;

  logic unused_mode;

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
`endif

  always_ff @(posedge clk_i) begin
    if (load_i) begin
      a_shadow_q <= load_a_i;
    end
    if (swap_i) begin
      a_active_q <= a_shadow_q;
    end
  end

  assign load_a_o = a_shadow_q;
  assign a_use    = swap_i ? a_shadow_q : a_active_q;
  assign a_ext    = {{(AccW - 8) {a_use[7]}}, a_use};

  // b = -b7*2^7 + sum_{i<7} b_i*2^i, so
  // a*b = sum_{i<7} b_i*(a << i) + b7*(~(a << 7) + 1)   (mod 2^AccW).
  // The +1 goes into bit 0 of row 1, which is always 0 there.
  for (genvar i = 0; i < 7; i++) begin : g_pp
    if (i == 1) begin : g_plus_one
      assign pp[i] = (b_i[i] ? (a_ext << i) : '0) | AccW'(b_i[7]);
    end else begin : g_row
      assign pp[i] = b_i[i] ? (a_ext << i) : '0;
    end
  end
  assign pp[7] = b_i[7] ? ~(a_ext << 7) : '0;

  // 10 rows (8 partial products + sum_i + carry_i) -> 2 rows.
  //   level 1: 10 -> 7   level 2: 7 -> 5   level 3: 5 -> 4   level 4: 4 -> 3   level 5: 3 -> 2
  assign {c10, s10} = csa(pp[0], pp[1], pp[2]);
  assign {c11, s11} = csa(pp[3], pp[4], pp[5]);
  assign {c12, s12} = csa(pp[6], pp[7], sum_i);

  assign {c20, s20} = csa(s10, c10, s11);
  assign {c21, s21} = csa(c11, s12, c12);

  assign {c30, s30} = csa(s20, c20, s21);
  assign {c40, s40} = csa(s30, c30, c21);
  assign {c50, s50} = csa(s40, c40, carry_i);

  always_ff @(posedge clk_i) begin
    b_o     <= b_i;
    sum_o   <= s50;
    carry_o <= c50;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      swap_o <= 1'b0;
    end else begin
      swap_o <= swap_i;
    end
  end

  assign unused_mode = mode_i;

endmodule
