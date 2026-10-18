// Block-scaling stage of bpu_sa_sram_wrapper: scales each drained row of integer
// block sums and accumulates the blocks of a tile in FP32.
//
// With block scaling, the reduction is split into blocks g of BlockK k-steps, and
// the array produces the exact integer sum of each block as its own tile. For row
// r of block g this stage computes, for every column j,
//
//   acc[r][j] = acc[r][j] + f32(isum[r][j]) * (f32(sA[r][g]) * f32(sB[g][j]))
//
// with acc starting at +0.0 for the first block, every product and add in IEEE
// binary32, round to nearest even, and the blocks added in increasing g. Scales
// are bf16; f32(bf16) appends 16 zero bits. On the tile's last block the finished
// row leaves on out_row_o instead of being stored.
// Each block sum must lie in -2^24 .. 2^24 - 1 (and fit AccW bits); the conversion
// to binary32 is then exact. The wrapper's block sums are within +-2^20.
//
// Datapath per column (latencies in cycles after the input register):
//   1  bpu_int2fp32 (exact)                  ||  bpu_fp32_mul sA * sB
//   3  bpu_fp32_mul f32(isum) * scale
//   3  bpu_fp32_add acc + product
// The FP32 units are in rtl/compute/fp; its README records how they were checked
// bit-exact against a host FPU.
//
// Flow: a valid-only pipeline, 8 cycles from in_valid_i to out_valid_o (LATENCY);
// it never stalls, so the wrapper admits a row only when it has room for the
// result. The same row may not re-enter while it is still in the pipeline
// (RowReuseSpacing_A); rows of consecutive blocks are at least one block of
// k-steps apart, which the wrapper guarantees is more than LATENCY.
//
// Clock and reset
//   clk_i   Rising-edge clock. The only clock domain.
//   rst_ni  Active-low reset. Assertion may be asynchronous; deassertion must be
//           synchronous to clk_i and meet recovery and removal timing. The
//           instantiating design owns that guarantee. Reset clears the valid
//           pipeline (rows in flight are dropped); the accumulators and data
//           registers are storage and are not reset (the first block of every
//           tile starts from +0.0 regardless).
module bpu_sa_scale_acc #(
  parameter int unsigned Rows = 8,  // rows of the C tile, >= 1
  parameter int unsigned Cols = 8,  // columns of the C tile, >= 1
  parameter int unsigned AccW = 32  // width of the integer block sums, >= 16
) (
  input logic clk_i,
  input logic rst_ni,

  // One row of integer block sums per valid cycle
  input logic                                     in_valid_i,
  input logic [                    Cols*AccW-1:0] in_row_i,    // isum[r][j], j = 0..Cols-1
  input logic [$clog2((Rows > 1) ? Rows : 2)-1:0] in_idx_i,    // r
  input logic                                     in_first_i,  // first block of the tile
  input logic                                     in_emit_i,   // last block: send the row out
  input logic                                     in_last_i,   // passed through to out_last_o
  input logic [                             15:0] in_sa_i,     // sA[r][g], bf16
  input logic [                      Cols*16-1:0] in_sb_i,     // sB[g][j], bf16

  // Finished FP32 rows (only for in_emit_i rows), LATENCY cycles later
  output logic               out_valid_o,
  output logic [Cols*32-1:0] out_row_o,
  output logic               out_last_o
);

  localparam int unsigned ROW_IDX_WIDTH = $clog2((Rows > 1) ? Rows : 2);
  localparam int unsigned INT_WIDTH = 25;  // bpu_int2fp32 input: -2^24 .. 2^24 - 1, exact
  // Cycles from the input register to the adder input (1 + 3) and to the output
  // (1 + 3 + 3). From in_valid_i, add the input register: 8 cycles in all.
  localparam int unsigned ADD_IN_DEPTH = 4;
  localparam int unsigned OUT_DEPTH = 7;

  // Input register.
  logic                           valid0_q;
  logic [    Cols*AccW-1:0]       row0_q;
  logic [ROW_IDX_WIDTH-1:0]       idx0_q;
  logic                           first0_q;
  logic                           emit0_q;
  logic                           last0_q;
  logic [             15:0]       sa0_q;
  logic [      Cols*16-1:0]       sb0_q;

  // Per-column datapath.
  logic [         Cols-1:0][31:0] isum_f;  // f32(isum), 1 cycle after the input
  logic [         Cols-1:0][31:0] scale;  // sA * sB, 1 cycle after the input
  logic [         Cols-1:0][31:0] prod;  // at the adder input
  logic [         Cols-1:0][31:0] addend;
  logic [         Cols-1:0][31:0] sum;  // at the output
  logic [         Cols-1:0][ 3:0] unused_valid;

  // Sideband: at the adder input, and at the output.
  logic [ROW_IDX_WIDTH-1:0]       idx_add;
  logic                           first_add;
  logic                           valid_out;
  logic [ROW_IDX_WIDTH-1:0]       idx_out;
  logic                           emit_out;
  logic                           last_out;

  // Accumulators: one FP32 row per array row, for blocks 0 .. G-2.
  logic [      Cols*32-1:0]       acc_q                                         [Rows];

`ifndef SYNTHESIS
  logic [Rows-1:0] rows_in_flight_q;  // rows still in the pipeline

  initial begin
    if (AccW < 16) begin
      $fatal(1, "bpu_sa_scale_acc: AccW = %0d is below 16", AccW);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rows_in_flight_q <= '0;
    end else begin
      for (int r = 0; r < Rows; r++) begin
        if (in_valid_i && in_idx_i == ROW_IDX_WIDTH'(r)) begin
          rows_in_flight_q[r] <= 1'b1;
        end else if (valid_out && idx_out == ROW_IDX_WIDTH'(r)) begin
          rows_in_flight_q[r] <= 1'b0;
        end
      end
    end
  end

  // in_valid_i is 0 during reset.
  always @(posedge clk_i) begin
    RowReuseSpacing_A :
    assert (!(in_valid_i === 1'b1 && rows_in_flight_q[in_idx_i] === 1'b1
              && !(valid_out && idx_out == in_idx_i)))
    else $error("bpu_sa_scale_acc: row %0d re-entered while still in the pipeline", in_idx_i);
  end
`endif

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid0_q <= 1'b0;
    end else begin
      valid0_q <= in_valid_i;
    end
  end

  always_ff @(posedge clk_i) begin
    if (in_valid_i) begin
      row0_q   <= in_row_i;
      idx0_q   <= in_idx_i;
      first0_q <= in_first_i;
      emit0_q  <= in_emit_i;
      last0_q  <= in_last_i;
      sa0_q    <= in_sa_i;
      sb0_q    <= in_sb_i;
    end
  end

  for (genvar j = 0; j < Cols; j++) begin : g_col
    bpu_int2fp32 #(
      .InW(INT_WIDTH),
      .Reg(1'b1)
    ) u_int2fp (
      .clk_i,
      .rst_ni,
      .valid_i(valid0_q),
      .x_i    (INT_WIDTH'($signed(row0_q[AccW*j+:AccW]))),
      .valid_o(unused_valid[j][0]),
      .y_o    (isum_f[j])
    );

    bpu_fp32_mul #(
      .PipeMask(3'b001)
    ) u_scale_mul (
      .clk_i,
      .rst_ni,
      .valid_i(valid0_q),
      .a_i    ({sa0_q, 16'h0000}),
      .b_i    ({sb0_q[16*j+:16], 16'h0000}),
      .valid_o(unused_valid[j][1]),
      .y_o    (scale[j])
    );

    bpu_fp32_mul #(
      .PipeMask(3'b111)
    ) u_prod_mul (
      .clk_i,
      .rst_ni,
      .valid_i(1'b1),
      .a_i    (isum_f[j]),
      .b_i    (scale[j]),
      .valid_o(unused_valid[j][2]),
      .y_o    (prod[j])
    );

    assign addend[j] = first_add ? 32'h0000_0000 : acc_q[idx_add][32*j+:32];

    bpu_fp32_add #(
      .PipeMask(3'b111)
    ) u_acc_add (
      .clk_i,
      .rst_ni,
      .valid_i(1'b1),
      .a_i    (addend[j]),
      .b_i    (prod[j]),
      .valid_o(unused_valid[j][3]),
      .y_o    (sum[j])
    );

    assign out_row_o[32*j+:32] = sum[j];
  end

  // idx and first, timed to the adder input; the rest timed to the output.
  bpu_sa_delay #(
    .Width(ROW_IDX_WIDTH + 1),
    .Depth(ADD_IN_DEPTH)
  ) u_side_add (
    .clk_i,
    .rst_ni,
    .d_i({idx0_q, first0_q}),
    .q_o({idx_add, first_add})
  );

  bpu_sa_delay #(
    .Width(1),
    .Depth(OUT_DEPTH),
    .Reset(1'b1)
  ) u_valid_out (
    .clk_i,
    .rst_ni,
    .d_i(valid0_q),
    .q_o(valid_out)
  );

  bpu_sa_delay #(
    .Width(ROW_IDX_WIDTH + 2),
    .Depth(OUT_DEPTH)
  ) u_side_out (
    .clk_i,
    .rst_ni,
    .d_i({idx0_q, emit0_q, last0_q}),
    .q_o({idx_out, emit_out, last_out})
  );

  // Blocks before the last are stored; the last block's row leaves instead.
  always_ff @(posedge clk_i) begin
    if (valid_out && !emit_out) begin
      acc_q[idx_out] <= out_row_o;
    end
  end

  assign out_valid_o = valid_out && emit_out;
  assign out_last_o  = last_out;

endmodule
