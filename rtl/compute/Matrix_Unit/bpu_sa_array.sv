// Int8 systolic array: C = A * B with A stationary in the PEs and B streaming in
// from the top. Partial sums travel between PEs in carry-save form (separate sum
// and carry vectors) and are resolved by one carry-propagate adder per row, at
// the array's right edge.
//
// Sources (one module per file; rtl/compute/Matrix_Unit/bpu_sa_array.f lists them):
//   bpu_sa_array.sv   this module: A tile loading, B input skew, PE grid, row adders,
//                     output deskew
//   bpu_sa_pe.sv      one processing element
//   bpu_sa_delay.sv   a shift-register delay line
//
// ---------------------------------------------------------------------------------
// Geometry
//
//   A is a Rows x Cols tile; PE(i,k) holds A[i][k]. One B column (Cols int8 values)
//   produces one C column (Rows values):  C[i] = sum over k of A[i][k] * B[k].
//
//            B[0]     B[1]     B[2]          B[k] enters column k, delayed k cycles
//              |        |        |
//      0 -> PE(0,0) -> PE(0,1) -> PE(0,2) -> (+) -> C[0]    sum + carry move right
//              |        |        |
//      0 -> PE(1,0) -> PE(1,1) -> PE(1,2) -> (+) -> C[1]    B moves down
//
//   The array skews B on the way in and deskews C on the way out, so callers see
//   whole columns: one B column in per cycle, one C column out per cycle.
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
//            same reset goes to every bpu_sa_pe and bpu_sa_delay inside.
//            Producers must hold a_valid_i and b_valid_i low while rst_ni is low;
//            anything presented during reset is discarded.
//
//   Reset cancels all accepted work:
//     * C columns in flight are discarded: c_valid_o is low while rst_ni is low
//       and stays low until a B column accepted after reset completes.
//     * A partly or fully loaded next tile is discarded: after reset a_full_o = 0
//       and a_ready_o = 1.
//     * The tile in use becomes undefined: load a complete tile before sending B.
//   Reset clears the control state (row count, reload hold-off, tile-switch flags,
//   output valid). A values, B data and partial sums are data storage and are not
//   reset; c_valid_o keeps their leftover contents from ever being reported.
//
// ---------------------------------------------------------------------------------
// Interface (all widths in bits, all latencies in clk_i cycles)
//
//   A tile   a_valid_i / a_ready_o / a_row_i: ready/valid; one row of A per transfer,
//            on a rising edge where both are high. Element k is the signed int8 in
//            bits [8k+7:8k]. Send the LAST row first: rows shift down from the top,
//            so after Rows transfers the first row sent sits in row Rows-1.
//            Capacity is one tile (Rows rows) in the PEs' shadow registers, so the
//            next tile can load while the current one computes. a_full_o = 1 means
//            a whole tile is waiting; a_ready_o is then 0. a_ready_o also stays 0
//            for Rows + Cols - 2 cycles after a tile switch, until the switch has
//            reached every PE. a_ready_o depends only on registers, never on
//            a_valid_i (no combinational handshake path).
//   B        b_valid_i / b_col_i: one column of B per cycle, element k in bits
//            [8k+7:8k]. Always accepted (b_ready_o = 1). The first B column that
//            arrives while a_full_o is high switches to the new tile: that column
//            and every later one use it. The switch travels through the array with
//            that column, so earlier columns still in flight keep the old tile.
//            Before any tile has been loaded, results are undefined.
//   C        c_valid_o / c_col_o: C[i] (signed, AccW bits) in bits [AccW*i +: AccW],
//            LATENCY_CYCLES = Rows + Cols + 1 cycles after its B column was
//            accepted, in the order the B columns were sent. There is no
//            backpressure: the consumer must take every column while c_valid_o is
//            high (put a FIFO behind it if the consumer can stall).
//   Errors   mode_i = 0 selects int8 x int8. mode_i = 1 (int4) is reserved and not
//            implemented: err_mode_o is high while it is selected, and the array
//            keeps computing int8. There are no other error conditions.
//
// Arithmetic
//
//   Signed int8 x signed int8, exact; sums are modulo 2^AccW, so AccW must be at
//   least 16 + clog2(Cols) for exact results (checked in simulation). The default
//   of 32 matches the "raw dot sums INT32" plan from the 10/03 compute meeting.
//
// Inside a PE (bpu_sa_pe): 8 partial products (sign-extended rows; the -2^7 row
// of B is negated as ~x + 1, with the +1 put in an empty bit of another row) plus
// the incoming sum and carry make 10 rows. Eight 3:2 carry-save adders, five
// levels deep, reduce them to 2 rows, which are registered. No carry propagates
// inside the array, so a PE's delay is a mux, an AND gate and five full adders,
// whatever AccW is.
//
// Knobs for the cost/benefit study:
//   * AccW: 32 is safe; 16 + clog2(Cols) is the minimum (fewer flops and adders).
//   * Sign extension: rows are fully sign-extended (simple, more full adders in the
//     high bits). The Baugh-Wooley or sign-extension-constant trick cuts that.
//   * Wallace (here) vs Dadda reduction: Dadda uses fewer full adders.
//   * Carry-save partial sums (here) double the psum flops and wires between PEs
//     but take the carry propagation out of every PE. The alternative resolves
//     sum + carry inside each PE (one adder per PE, half the psum flops).
//   * Valid-based clock gating: idle B slots are fed as zeros to cut toggling;
//     PE registers still clock every cycle.
// ---------------------------------------------------------------------------------
module bpu_sa_array #(
  parameter int unsigned Rows = 8,  // rows of the A tile = outputs per B column, >= 1
  parameter int unsigned Cols = 8,  // columns of the A tile = reduction length, >= 1
  parameter int unsigned AccW = 32  // accumulator width in bits, >= 16 + clog2(Cols)
) (
  input logic clk_i,
  input logic rst_ni,

  input  logic mode_i,     // 0: int8; 1: int4 (not implemented)
  output logic err_mode_o,

  // A tile, one row per transfer, last row first
  input  logic              a_valid_i,
  output logic              a_ready_o,
  input  logic [Cols*8-1:0] a_row_i,
  output logic              a_full_o,

  // B, one column per cycle
  input  logic              b_valid_i,
  output logic              b_ready_o,
  input  logic [Cols*8-1:0] b_col_i,

  // C, one column per accepted B column, LATENCY_CYCLES later
  output logic                 c_valid_o,
  output logic [Rows*AccW-1:0] c_col_o
);

  localparam int unsigned LATENCY_CYCLES = Rows + Cols + 1;
  localparam int unsigned HOLD_CYCLES = Rows + Cols - 2;
  localparam int unsigned MIN_ACC_WIDTH = 16 + $clog2(Cols);
  localparam int unsigned A_COUNT_WIDTH = $clog2(Rows + 1);
  localparam int unsigned HOLD_COUNT_WIDTH = (HOLD_CYCLES > 0) ? $clog2(HOLD_CYCLES + 1) : 1;

  // Control: shadow fill count, tile switch, reload hold-off.
  logic [A_COUNT_WIDTH-1:0] a_cnt_q;  // rows of the next tile in the shadow registers
  logic [HOLD_COUNT_WIDTH-1:0] hold_q;  // cycles until the last tile switch reaches every PE
  logic a_fire;
  logic swap;

  // B input register and skew.
  logic [Cols-1:0][7:0] b_q;
  logic [Cols-1:0][7:0] top_b;
  logic swap_q;
  logic [Cols-1:0] top_swap;

  // PE grid. Each array holds every PE's outputs; inputs come from the neighbours.
  logic [Cols-1:0][7:0] a_top;
  logic [Rows-1:0][Cols-1:0][7:0] a_dn;  // going down: shadow-chain A values
  logic [Rows-1:0][Cols-1:0][7:0] b_dn;  // going down: B values
  logic [Rows-1:0][Cols-1:0] swap_dn;  // going down: tile-switch flags
  logic [Rows-1:0][Cols-1:0][AccW-1:0] sum_rt;  // going right: carry-save sum
  logic [Rows-1:0][Cols-1:0][AccW-1:0] carry_rt;  // going right: carry-save carry

  // Row edge: resolved row sums, deskewed sums, output register.
  logic [Rows-1:0][AccW-1:0] row_c;
  logic [Rows-1:0][AccW-1:0] row_al;
  logic [Rows-1:0][AccW-1:0] c_q;

  // The bottom row's downward outputs have no consumer.
  logic unused_bottom;

`ifndef SYNTHESIS
  initial begin
    if (Rows < 1 || Cols < 1) begin
      $fatal(1, "bpu_sa_array: Rows and Cols must be at least 1");
    end
    if (AccW < MIN_ACC_WIDTH) begin
      $fatal(1, "bpu_sa_array: AccW = %0d is below 16 + clog2(Cols) = %0d", AccW, MIN_ACC_WIDTH);
    end
  end
`endif

  assign err_mode_o = mode_i;
  assign b_ready_o  = 1'b1;

  // ---------------------------------------------------------------------------
  // Control: shadow fill count, tile switch, reload hold-off
  // ---------------------------------------------------------------------------
  assign a_full_o   = (a_cnt_q == A_COUNT_WIDTH'(Rows));
  assign a_ready_o  = !a_full_o && (hold_q == '0);
  assign a_fire     = a_valid_i && a_ready_o;
  assign swap       = b_valid_i && a_full_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      a_cnt_q <= '0;
      hold_q  <= '0;
    end else if (swap) begin
      a_cnt_q <= '0;
      hold_q  <= HOLD_COUNT_WIDTH'(HOLD_CYCLES);
    end else begin
      if (a_fire) begin
        a_cnt_q <= a_cnt_q + 1'b1;
      end
      if (hold_q != '0) begin
        hold_q <= hold_q - 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // B input register and skew: column k is delayed k cycles
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    b_q <= b_valid_i ? b_col_i : '0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      swap_q <= 1'b0;
    end else begin
      swap_q <= swap;
    end
  end

  for (genvar k = 0; k < Cols; k++) begin : g_skew
    bpu_sa_delay #(
      .Width(8),
      .Depth(k)
    ) u_b (
      .clk_i,
      .rst_ni,
      .d_i(b_q[k]),
      .q_o(top_b[k])
    );
    bpu_sa_delay #(
      .Width(1),
      .Depth(k),
      .Reset(1'b1)
    ) u_swap (
      .clk_i,
      .rst_ni,
      .d_i(swap_q),
      .q_o(top_swap[k])
    );
  end

  // ---------------------------------------------------------------------------
  // PE grid
  // ---------------------------------------------------------------------------
  assign a_top = a_row_i;

  for (genvar i = 0; i < Rows; i++) begin : g_row
    for (genvar k = 0; k < Cols; k++) begin : g_col
      logic [7:0] a_in;
      logic [7:0] b_in;
      logic swap_in;
      logic [AccW-1:0] sum_in;
      logic [AccW-1:0] carry_in;

      if (i == 0) begin : g_top
        assign a_in    = a_top[k];
        assign b_in    = top_b[k];
        assign swap_in = top_swap[k];
      end else begin : g_below
        assign a_in    = a_dn[i-1][k];
        assign b_in    = b_dn[i-1][k];
        assign swap_in = swap_dn[i-1][k];
      end

      if (k == 0) begin : g_left
        assign sum_in   = '0;
        assign carry_in = '0;
      end else begin : g_right
        assign sum_in   = sum_rt[i][k-1];
        assign carry_in = carry_rt[i][k-1];
      end

      bpu_sa_pe #(
        .AccW(AccW)
      ) u_pe (
        .clk_i,
        .rst_ni,
        .mode_i,
        .load_i  (a_fire),
        .load_a_i(a_in),
        .load_a_o(a_dn[i][k]),
        .b_i     (b_in),
        .swap_i  (swap_in),
        .b_o     (b_dn[i][k]),
        .swap_o  (swap_dn[i][k]),
        .sum_i   (sum_in),
        .carry_i (carry_in),
        .sum_o   (sum_rt[i][k]),
        .carry_o (carry_rt[i][k])
      );
    end
  end

  assign unused_bottom = ^{a_dn[Rows-1], b_dn[Rows-1], swap_dn[Rows-1]};

  // ---------------------------------------------------------------------------
  // Row edge: resolve sum + carry, deskew (row i is i cycles later than row 0),
  // register the whole column
  // ---------------------------------------------------------------------------
  for (genvar i = 0; i < Rows; i++) begin : g_edge
    assign row_c[i] = sum_rt[i][Cols-1] + carry_rt[i][Cols-1];

    bpu_sa_delay #(
      .Width(AccW),
      .Depth(Rows - 1 - i)
    ) u_deskew (
      .clk_i,
      .rst_ni,
      .d_i(row_c[i]),
      .q_o(row_al[i])
    );
  end

  always_ff @(posedge clk_i) begin
    c_q <= row_al;
  end

  assign c_col_o = c_q;

  bpu_sa_delay #(
    .Width(1),
    .Depth(LATENCY_CYCLES),
    .Reset(1'b1)
  ) u_valid (
    .clk_i,
    .rst_ni,
    .d_i(b_valid_i),
    .q_o(c_valid_o)
  );

endmodule
