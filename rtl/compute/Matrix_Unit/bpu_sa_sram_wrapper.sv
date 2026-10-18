// SRAM wrapper for bpu_sa_array: runs one matrix-multiply command at a time,
//   unscaled      C = A * B, exact INT32 (BYTE_DOT in the 10-03 slides), or
//   block-scaled  C = sum over blocks g of (A_g * B_g) scaled by bf16 block scales,
//                 in FP32,
// with INT8 activations A and INT8 or packed INT4 weights B. It reads the
// operands from the on-chip SRAM through the sram_arbiter matrix port, feeds the
// output-stationary array, and writes the finished C tile back through the same
// port.
//
// Sources (one module per file; rtl/compute/Matrix_Unit/bpu_sa_array.f lists them):
//   bpu_sa_sram_wrapper.sv   this module: command, read arbitration, feed, drain,
//                            C write-back
//   bpu_sa_read_stream.sv    one read stream (A, B, and the two scale tables)
//   bpu_sa_scale_acc.sv      block-scaling stage: FP32 multiply-accumulate per row
//   bpu_sa_fifo.sv           buffers and queues
//   bpu_sa_array.sv          the systolic array (with bpu_sa_pe.sv, bpu_sa_delay.sv)
//   rtl/compute/fp, rtl/compute/common   the FP32 units bpu_sa_scale_acc uses
//
// ---------------------------------------------------------------------------------
// Memory layout (byte addresses; one SRAM row = DataW/8 bytes, 512 by default)
//
//   A   Rows x K int8, k-major: A[i][k] at a_addr + k*Rows + i. Column k of A, the
//       Rows values one k-step needs, is Rows consecutive bytes.
//   B   K x Cols, row-major. INT8: B[k][j] at b_addr + k*Cols + j.
//       INT4 (cmd_int4_i = 1): two signed codes per byte, low nibble first:
//       B[k][j] is nibble n = k*Cols + j, in byte b_addr + n/2, low nibble when n
//       is even (W4, WFMT_W4 in bpu_compute_pkg).
//   SA  activation scales (block-scaled only), bf16, block-major:
//       sA[i][g] at sa_addr + 2*(g*Rows + i), little-endian.
//   SB  weight scales (block-scaled only), bf16, block-major:
//       sB[g][j] at sb_addr + 2*(g*Cols + j), little-endian.
//   C   Rows x Cols, row-major, 4 bytes little-endian each: C[r][j] at
//       c_addr + 4*(r*Cols + j). Unscaled: int32, sign-extended from AccW.
//       Block-scaled: IEEE binary32.
//   Every base address must be row aligned. The wrapper writes exactly the
//   Rows*Cols*4 bytes of C and nothing else.
//
// ---------------------------------------------------------------------------------
// Arithmetic
//
//   Unscaled: as bpu_sa_array; exact while K < 2^(AccW-15) for INT8 B.
//   Block-scaled: K splits into G = K / BlockK blocks, and
//     C[i][j] = sum over g = 0..G-1, in increasing g, of
//               f32(isum[i][j][g]) * (f32(sA[i][g]) * f32(sB[g][j]))
//   where isum is the exact integer sum over block g and every product and add is
//   IEEE binary32, round to nearest even, starting from +0.0. Each block runs as
//   its own array tile; the block's rows drain into bpu_sa_scale_acc while the
//   next block accumulates.
//   INT4 B runs the array in its INT4-pair mode: two k-steps per array step, so
//   twice the MACs per cycle. With an odd K the last pair's second half is zeroed.
//
// ---------------------------------------------------------------------------------
// Clock and reset
//
//   clk_i    Rising-edge clock. Every port is in this single clock domain.
//   rst_ni   Active-low reset. Assertion may be asynchronous; deassertion must be
//            synchronous to clk_i and meet recovery and removal timing. The
//            instantiating design owns that guarantee. The same reset goes to every
//            submodule.
//
//   Reset cancels the command in progress: no done_o pulse is sent for it, and the
//   SRAM may hold a partly written C. The sram_arbiter must be reset with it and
//   must drop any response still in flight (its proposed reset contract); a
//   response that arrived after reset would be taken as data for the next
//   command. Reset clears the control state (command, counters, credits, request
//   valid, FIFO pointers, pipeline valids); row buffers, staging rows, accumulators
//   and request payload registers are data storage.
//
// ---------------------------------------------------------------------------------
// Interface (all latencies in clk_i cycles)
//
//   Command  cmd_valid_i / cmd_ready_o: ready/valid. cmd_ready_o = !busy_o, so one
//            command runs at a time; it depends only on registers.
//            cmd_k_i is K, 1 .. 2^KW - 1. cmd_int4_i: B is packed INT4.
//            cmd_scaled_i: block-scaled, FP32 C; cmd_sa_addr_i and cmd_sb_addr_i
//            are then the scale tables (ignored otherwise).
//            busy_o is high from the cycle after the command is accepted until
//            the command completes. done_o pulses for one cycle when it has, in
//            the first cycle busy_o is low again.
//            An illegal command is accepted, touches no memory, and gets done_o
//            and err_o together one cycle later. err_o is never high without
//            done_o. Illegal: K = 0; a base address in use that is not row
//            aligned; cmd_int4_i in a build without Int4; cmd_scaled_i in a build
//            without Scale, or with K not a multiple of BlockK.
//   SRAM     matrix_req_* drive the sram_arbiter matrix request port
//            (ready/valid). A request and its payload stay unchanged from the
//            cycle valid rises until the cycle ready is 1. All of them depend
//            only on registers.
//            Reads: one SRAM row per request, size_bytes = DataW/8, except an
//            operand's last read, which asks for exactly the bytes that remain.
//            Byte n of matrix_rsp_rdata_i (bits [8n+7:8n]) must be the byte at the
//            request address + n. Of the streams that can take a read, the one
//            with the fewest rows reserved goes first (A, B, SA, SB on a tie).
//            Writes: up to one SRAM row of C per request; byte n of
//            matrix_req_wdata_o is written to the request address + n, and
//            size_bytes covers exactly the C bytes in the request.
//            matrix_rsp_valid_i: a one-cycle pulse per read, in request order,
//            carrying matrix_rsp_rdata_i, with no backpressure. The wrapper only
//            issues a read when its buffer has room for the response.
//            WriteAcks = 0 (default): writes get no response, as the arbiter's
//            I/O scheme (docs/memory/sram_arbiter_io_scheme.md) specifies, and
//            done_o follows the last write's acceptance. WriteAcks = 1: for an
//            arbiter that also pulses matrix_rsp_valid_i once per write; done_o
//            then waits for the last one.
//            The wrapper never has reads and writes outstanding at once
//            (NoReadWriteOverlap_A), so the two kinds of response are never
//            confused.
//
// Timing, from accepting the command (L = SRAM round trip, request to response):
//   the first k-step enters the array about L + 2 cycles later, once the first A
//   and B rows are back; array steps then stream one per cycle while the buffers
//   keep up. C rows start Rows + Cols - 1 cycles after the last array step
//   (unscaled) or 8 cycles later still (block-scaled), and are written one SRAM row
//   at a time. With block scaling the blocks stream without stalls while a block's
//   array steps (BlockK, or BlockK/2 for INT4) are at least 2 * Rows + Cols.
//
// Knobs: Rows, Cols, AccW (the array); Int4 (INT4-pair PEs) and Scale (the block-
//   scaling stage), each removable to save area; BlockK; DataW, SizeW, AddrW (the
//   arbiter port: sram_arbiter_pkg DATA_WIDTH, SIZE_WIDTH, ADDR_WIDTH); BufRows
//   (read-ahead per stream); OutDepth (finished rows queued for write-back);
//   WriteAcks (the arbiter's write-response behaviour).
// ---------------------------------------------------------------------------------
module bpu_sa_sram_wrapper #(
  parameter int unsigned Rows      = 8,     // power of two, 1 .. DataW/16
  parameter int unsigned Cols      = 8,     // power of two, 1 .. DataW/32 (2+ with Int4)
  parameter int unsigned AccW      = 32,    // accumulator width, 16 .. 32
  parameter int unsigned AddrW     = 32,    // address width (ADDR_WIDTH)
  parameter int unsigned DataW     = 4096,  // SRAM row in bits (DATA_WIDTH), 8 * 2^n
  parameter int unsigned SizeW     = 10,    // size_bytes width (SIZE_WIDTH)
  parameter int unsigned KW        = 16,    // width of cmd_k_i
  parameter int unsigned BufRows   = 2,     // SRAM rows buffered per stream, >= 1
  parameter bit          WriteAcks = 1'b0,  // 1: every write also gets a response pulse
  parameter bit          Int4      = 1'b1,  // 1: support packed INT4 weights
  parameter bit          Scale     = 1'b1,  // 1: support block scaling
  parameter int unsigned BlockK    = 64,    // k-steps per scale block, power of two 32..1024
  parameter int unsigned OutDepth  = 9      // finished C rows queued for write-back, >= 1
) (
  input logic clk_i,
  input logic rst_ni,

  // Command and status
  input  logic             cmd_valid_i,
  output logic             cmd_ready_o,
  input  logic [AddrW-1:0] cmd_a_addr_i,
  input  logic [AddrW-1:0] cmd_b_addr_i,
  input  logic [AddrW-1:0] cmd_c_addr_i,
  input  logic [AddrW-1:0] cmd_sa_addr_i,
  input  logic [AddrW-1:0] cmd_sb_addr_i,
  input  logic [   KW-1:0] cmd_k_i,
  input  logic             cmd_int4_i,
  input  logic             cmd_scaled_i,
  output logic             busy_o,
  output logic             done_o,
  output logic             err_o,

  // sram_arbiter matrix port
  output logic             matrix_req_valid_o,
  input  logic             matrix_req_ready_i,
  output logic             matrix_req_is_write_o,
  output logic [SizeW-1:0] matrix_req_size_bytes_o,
  output logic [AddrW-1:0] matrix_req_addr_o,
  output logic [DataW-1:0] matrix_req_wdata_o,
  input  logic             matrix_rsp_valid_i,
  input  logic [DataW-1:0] matrix_rsp_rdata_i
);

  localparam int unsigned ROW_BYTES = DataW / 8;
  localparam int unsigned ROW_OFFSET_WIDTH = $clog2(ROW_BYTES);
  // Read streams.
  localparam int unsigned NUM_STREAMS = 4;
  localparam int unsigned S_A = 0;
  localparam int unsigned S_B = 1;
  localparam int unsigned S_SA = 2;
  localparam int unsigned S_SB = 3;
  // Array steps per SRAM row: A in INT8 and INT4 mode, B (Cols bytes per step in
  // both modes); scale blocks per SRAM row; C rows per write.
  localparam int unsigned A_STEPS8 = ROW_BYTES / Rows;
  localparam int unsigned A_STEPS4 = (Rows * 2 <= ROW_BYTES) ? ROW_BYTES / (2 * Rows) : 1;
  localparam int unsigned B_STEPS = ROW_BYTES / Cols;
  localparam int unsigned SA_BLOCKS = (Rows * 2 <= ROW_BYTES) ? ROW_BYTES / (2 * Rows) : 1;
  localparam int unsigned SB_BLOCKS = ROW_BYTES / (2 * Cols);
  localparam int unsigned C_ROW_BYTES = 4 * Cols;
  localparam int unsigned C_ROWS_PER_WRITE = ROW_BYTES / C_ROW_BYTES;
  localparam int unsigned A_SLOT_WIDTH = $clog2((A_STEPS8 > 1) ? A_STEPS8 : 2);
  localparam int unsigned B_SLOT_WIDTH = $clog2((B_STEPS > 1) ? B_STEPS : 2);
  localparam int unsigned SA_SLOT_WIDTH = $clog2((SA_BLOCKS > 1) ? SA_BLOCKS : 2);
  localparam int unsigned SB_SLOT_WIDTH = $clog2((SB_BLOCKS > 1) ? SB_BLOCKS : 2);
  localparam int unsigned C_SLOT_WIDTH = $clog2((C_ROWS_PER_WRITE > 1) ? C_ROWS_PER_WRITE : 2);
  localparam int unsigned BSTEP_WIDTH = $clog2(BlockK);
  localparam int unsigned BLOCK_SHIFT = $clog2(BlockK);
  localparam int unsigned CREDIT_WIDTH = $clog2(BufRows + 1);
  localparam int unsigned OUT_CREDIT_WIDTH = $clog2(OutDepth + 1);
  // Bytes of one stream: at most K * Rows or K * Cols <= (2^KW - 1) * ROW_BYTES.
  localparam int unsigned BYTES_WIDTH = KW + ROW_OFFSET_WIDTH;
  // Writes waiting for a response: at most one per C row.
  localparam int unsigned ACK_WIDTH = $clog2(Rows + 1);
  localparam int unsigned ROW_IDX_WIDTH = $clog2((Rows > 1) ? Rows : 2);
  // A lanes into the array, and the A bytes one array step can take.
  localparam int unsigned A_LANE = Int4 ? 16 : 8;
  localparam int unsigned A_WIN_BITS = Int4 ? 16 * Rows : 8 * Rows;

  // Command.
  logic                                          cmd_fire;
  logic                                          cmd_bad;
  logic                                          busy_q;
  logic                                          done_q;
  logic                                          err_q;
  logic                                          finish;
  logic                                          int4_q;  // B is packed INT4
  logic                                          scaled_q;  // block-scaled command
  logic                                          odd_q;  // INT4 with an odd K
  logic [              KW-1:0]                   k_last_q;  // array steps - 1
  logic [              KW-1:0]                   g_last_q;  // scale blocks - 1
  logic [     BSTEP_WIDTH-1:0]                   bstep_last_q;  // array steps per block - 1
  logic [    A_SLOT_WIDTH-1:0]                   a_slot_last_q;  // A steps per SRAM row - 1
  logic [              KW-1:0]                   cmd_steps;
  logic [              KW-1:0]                   cmd_blocks;

  // Read streams.
  logic [     NUM_STREAMS-1:0]                   st_start;
  logic [     NUM_STREAMS-1:0][       AddrW-1:0] st_addr;
  logic [     NUM_STREAMS-1:0][ BYTES_WIDTH-1:0] st_bytes;
  logic [     NUM_STREAMS-1:0]                   st_want;
  logic [     NUM_STREAMS-1:0][CREDIT_WIDTH-1:0] st_credit;
  logic [     NUM_STREAMS-1:0]                   st_grant;
  logic [     NUM_STREAMS-1:0][       AddrW-1:0] st_req_addr;
  logic [     NUM_STREAMS-1:0][       SizeW-1:0] st_req_size;
  logic [     NUM_STREAMS-1:0]                   st_push;
  logic [     NUM_STREAMS-1:0]                   st_pop;
  logic [     NUM_STREAMS-1:0][       DataW-1:0] st_head;
  logic [     NUM_STREAMS-1:0]                   st_empty;
  logic                                          pick_valid;
  logic [                 1:0]                   pick;

  // Request register: what matrix_req_* show.
  logic                                          req_valid_q;
  logic                                          req_is_write_q;
  logic [                 1:0]                   req_stream_q;  // the read's stream
  logic [           SizeW-1:0]                   req_size_q;
  logic [           AddrW-1:0]                   req_addr_q;
  logic                                          req_fire;
  logic                                          req_free;  // can take a new request now
  logic                                          load_read;

  // Responses: the read-order queue names the stream of each read in flight.
  logic [                 1:0]                   order_head;
  logic                                          order_empty;
  logic                                          order_full;
  logic                                          rsp_read;
  logic                                          rsp_ack;
  logic [       ACK_WIDTH-1:0]                   acks_left_q;

  // Feed: one array step per cycle from the A and B head rows.
  logic [    A_SLOT_WIDTH-1:0]                   a_slot_q;  // step within the A head row
  logic [    B_SLOT_WIDTH-1:0]                   b_slot_q;  // step within the B head row
  logic [              KW-1:0]                   k_q;  // next array step
  logic [     BSTEP_WIDTH-1:0]                   bstep_q;  // step within the scale block
  logic                                          feed_done_q;
  logic                                          feed_valid;
  logic                                          feed_fire;
  logic                                          feed_final;  // the command's last step
  logic                                          feed_first;  // first step of a tile
  logic                                          feed_last;  // last step of a tile
  logic [DataW+A_WIN_BITS-1:0]                   a_head_ext;
  logic [      A_WIN_BITS-1:0]                   a_win;
  logic [          Cols*8-1:0]                   b_win;

  // Array ports.
  logic                                          sa_in_ready;
  logic [     Rows*A_LANE-1:0]                   sa_in_a;
  logic [          Cols*8-1:0]                   sa_in_b;
  logic                                          sa_out_valid;
  logic                                          sa_out_ready;
  logic [       Cols*AccW-1:0]                   sa_out_row;
  logic [   ROW_IDX_WIDTH-1:0]                   sa_out_row_idx;
  logic                                          sa_out_last;
  logic                                          sa_err_mode;
  logic                                          sa_out_fire;

  // Drain: which block is coming out, its scales, and room for finished rows.
  logic [              KW-1:0]                   g_q;  // block draining
  logic [   SA_SLOT_WIDTH-1:0]                   sa_slot_q;  // block within the SA head row
  logic [   SB_SLOT_WIDTH-1:0]                   sb_slot_q;  // block within the SB head row
  logic                                          emit;  // this block's rows are final
  logic                                          scales_ok;
  logic                                          block_end;
  logic [                15:0]                   sa_bits;
  logic [         Cols*16-1:0]                   sb_bits;
  logic [OUT_CREDIT_WIDTH-1:0]                   out_credit_q;  // free queue entries
  logic                                          sc_valid;
  logic [         Cols*32-1:0]                   sc_row;
  logic                                          sc_last;
  logic [         Cols*32-1:0]                   c_row32;  // unscaled row, int32

  // Finished rows queued for write-back, and the C staging row.
  logic                                          out_push;
  logic [           Cols*32:0]                   out_data;  // {last, row}
  logic [           Cols*32:0]                   out_head;
  logic                                          out_empty;
  logic                                          out_full;
  logic                                          c_pop;
  logic [           DataW-1:0]                   c_stage_q;
  logic [           AddrW-1:0]                   c_addr_q;  // address of the staging row
  logic [    C_SLOT_WIDTH-1:0]                   c_slot_q;  // next row's place in it
  logic                                          c_write;  // the staging row is complete
  logic                                          c_done_q;  // the last C row is staged

  logic                                          unused_signals;

`ifndef SYNTHESIS
  initial begin
    if (DataW < 8 || (DataW % 8) != 0 || (ROW_BYTES & (ROW_BYTES - 1)) != 0) begin
      $fatal(1, "bpu_sa_sram_wrapper: DataW = %0d must be 8 times a power of two", DataW);
    end
    if (Rows < 1 || (Rows & (Rows - 1)) != 0 || Rows > ROW_BYTES) begin
      $fatal(1, "bpu_sa_sram_wrapper: Rows = %0d must be a power of two <= DataW/8", Rows);
    end
    if (Cols < 1 || (Cols & (Cols - 1)) != 0 || C_ROW_BYTES > ROW_BYTES) begin
      $fatal(1, "bpu_sa_sram_wrapper: Cols = %0d must be a power of two <= DataW/32", Cols);
    end
    if (AccW < 16 || AccW > 32) begin
      $fatal(1, "bpu_sa_sram_wrapper: AccW = %0d must be 16 .. 32", AccW);
    end
    if ((1 << SizeW) <= ROW_BYTES || AddrW <= ROW_OFFSET_WIDTH || KW < 1 || BufRows < 1
        || OutDepth < 1) begin
      $fatal(1, "bpu_sa_sram_wrapper: SizeW, AddrW, KW, BufRows or OutDepth too small");
    end
    if (Int4 && (Cols < 2 || 2 * Rows > ROW_BYTES)) begin
      $fatal(1, "bpu_sa_sram_wrapper: Int4 needs Cols >= 2 and Rows <= DataW/16");
    end
    if (Scale && ((BlockK & (BlockK - 1)) != 0 || BlockK < 32 || BlockK > 1024
                  || 2 * Rows > ROW_BYTES)) begin
      $fatal(1, "bpu_sa_sram_wrapper: Scale needs BlockK a power of two in 32..1024 %s",
             "and Rows <= DataW/16");
    end
    // A block sum is at most 16384 * BlockK and must fit AccW bits, signed.
    if (Scale && AccW < BLOCK_SHIFT + 16) begin
      $fatal(1, "bpu_sa_sram_wrapper: Scale with BlockK = %0d needs AccW >= %0d", BlockK,
             BLOCK_SHIFT + 16);
    end
  end

  // Every response must belong to a read in flight or, with WriteAcks, to a write.
  // matrix_rsp_valid_i is 0 during reset.
  always @(posedge clk_i) begin
    ExpectedResponse_A :
    assert (matrix_rsp_valid_i !== 1'b1 || !order_empty || (WriteAcks && acks_left_q != '0))
    else $error("bpu_sa_sram_wrapper: response with no read or write outstanding");
    NoReadWriteOverlap_A :
    assert (!(c_write === 1'b1 && !order_empty))
    else $error("bpu_sa_sram_wrapper: C write while reads are in flight");
  end
`endif

  // Arbitration: the wanting stream with the fewest rows reserved; lowest index on
  // a tie.
  function automatic logic [2:0] arbitrate(input logic [NUM_STREAMS-1:0] want,
                                           input logic [NUM_STREAMS-1:0][CREDIT_WIDTH-1:0] credit);
    logic                    found;
    logic [             1:0] best;
    logic [CREDIT_WIDTH-1:0] best_credit;
    found       = 1'b0;
    best        = '0;
    best_credit = '0;
    for (int s = 0; s < NUM_STREAMS; s++) begin
      if (want[s] && (!found || credit[s] < best_credit)) begin
        found       = 1'b1;
        best        = 2'(s);
        best_credit = credit[s];
      end
    end
    return {found, best};
  endfunction

  // ---------------------------------------------------------------------------
  // Command
  // ---------------------------------------------------------------------------
  assign cmd_ready_o = !busy_q;
  assign busy_o = busy_q;
  assign done_o = done_q;
  assign err_o = err_q;
  assign cmd_fire = cmd_valid_i && cmd_ready_o;
  assign cmd_bad = (cmd_k_i == '0)
      || (cmd_a_addr_i[ROW_OFFSET_WIDTH-1:0] != '0)
      || (cmd_b_addr_i[ROW_OFFSET_WIDTH-1:0] != '0)
      || (cmd_c_addr_i[ROW_OFFSET_WIDTH-1:0] != '0)
      || (cmd_int4_i && !Int4)
      || (cmd_scaled_i && (!Scale || (cmd_k_i[BLOCK_SHIFT-1:0] != '0)
                           || (cmd_sa_addr_i[ROW_OFFSET_WIDTH-1:0] != '0)
                           || (cmd_sb_addr_i[ROW_OFFSET_WIDTH-1:0] != '0)));
  // Array steps: K, or ceil(K / 2) pairs in INT4 mode. Scale blocks: K / BlockK.
  assign cmd_steps = cmd_int4_i ? (cmd_k_i >> 1) + KW'(cmd_k_i[0]) : cmd_k_i;
  assign cmd_blocks = cmd_k_i >> BLOCK_SHIFT;
  // Done: the whole tile is staged, its last write accepted and, with WriteAcks,
  // answered.
  assign finish = busy_q && c_done_q && !req_valid_q && (acks_left_q == '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q        <= 1'b0;
      done_q        <= 1'b0;
      err_q         <= 1'b0;
      int4_q        <= 1'b0;
      scaled_q      <= 1'b0;
      odd_q         <= 1'b0;
      k_last_q      <= '0;
      g_last_q      <= '0;
      bstep_last_q  <= '0;
      a_slot_last_q <= '0;
    end else begin
      done_q <= 1'b0;
      err_q  <= 1'b0;
      if (cmd_fire) begin
        if (cmd_bad) begin
          done_q <= 1'b1;
          err_q  <= 1'b1;
        end else begin
          busy_q        <= 1'b1;
          int4_q        <= cmd_int4_i;
          scaled_q      <= cmd_scaled_i;
          odd_q         <= cmd_int4_i && cmd_k_i[0];
          k_last_q      <= cmd_steps - 1'b1;
          g_last_q      <= cmd_blocks - 1'b1;
          bstep_last_q  <= cmd_int4_i ? BSTEP_WIDTH'(BlockK / 2 - 1) : BSTEP_WIDTH'(BlockK - 1);
          a_slot_last_q <= cmd_int4_i ? A_SLOT_WIDTH'(A_STEPS4 - 1) : A_SLOT_WIDTH'(A_STEPS8 - 1);
        end
      end else if (finish) begin
        busy_q <= 1'b0;
        done_q <= 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Read streams and the request register
  // ---------------------------------------------------------------------------
  assign st_start = {NUM_STREAMS{cmd_fire && !cmd_bad}};
  assign st_addr[S_A] = cmd_a_addr_i;
  assign st_addr[S_B] = cmd_b_addr_i;
  assign st_addr[S_SA] = cmd_sa_addr_i;
  assign st_addr[S_SB] = cmd_sb_addr_i;
  assign st_bytes[S_A] = BYTES_WIDTH'(cmd_k_i) * BYTES_WIDTH'(Rows);
  assign st_bytes[S_B] = cmd_int4_i ? (BYTES_WIDTH'(cmd_k_i) * BYTES_WIDTH'(Cols)) >> 1
                                    : BYTES_WIDTH'(cmd_k_i) * BYTES_WIDTH'(Cols);
  assign st_bytes[S_SA] = cmd_scaled_i ? BYTES_WIDTH'(cmd_blocks) * BYTES_WIDTH'(2 * Rows) : '0;
  assign st_bytes[S_SB] = cmd_scaled_i ? BYTES_WIDTH'(cmd_blocks) * BYTES_WIDTH'(2 * Cols) : '0;

  for (genvar s = 0; s < NUM_STREAMS; s++) begin : g_stream
    if (s < 2 || Scale) begin : g_on
      bpu_sa_read_stream #(
        .AddrW  (AddrW),
        .DataW  (DataW),
        .SizeW  (SizeW),
        .BytesW (BYTES_WIDTH),
        .BufRows(BufRows)
      ) u_stream (
        .clk_i,
        .rst_ni,
        .start_i   (st_start[s]),
        .addr_i    (st_addr[s]),
        .bytes_i   (st_bytes[s]),
        .want_o    (st_want[s]),
        .credit_o  (st_credit[s]),
        .grant_i   (st_grant[s]),
        .req_addr_o(st_req_addr[s]),
        .req_size_o(st_req_size[s]),
        .push_i    (st_push[s]),
        .data_i    (matrix_rsp_rdata_i),
        .pop_i     (st_pop[s]),
        .head_o    (st_head[s]),
        .empty_o   (st_empty[s])
      );
    end else begin : g_off
      // Scale streams in a build without Scale: never started, never used.
      logic unused_stream;

      assign unused_stream    = ^{st_start[s], st_addr[s], st_bytes[s], st_grant[s], st_push[s],
                                  st_pop[s]};
      assign st_want[s] = 1'b0;
      assign st_credit[s] = '0;
      assign st_req_addr[s] = '0;
      assign st_req_size[s] = '0;
      assign st_head[s] = '0;
      assign st_empty[s] = 1'b1;
    end
  end

  assign {pick_valid, pick} = arbitrate(st_want, st_credit);
  assign req_fire = req_valid_q && matrix_req_ready_i;
  assign req_free = !req_valid_q || req_fire;
  // A C write cannot coincide with a read: every read is back before the first
  // finished row reaches the write-back, so no stream wants by then.
  assign load_read = req_free && !c_write && pick_valid;

  for (genvar s = 0; s < NUM_STREAMS; s++) begin : g_grant
    assign st_grant[s] = load_read && (pick == 2'(s));
    assign st_push[s]  = rsp_read && (order_head == 2'(s));
  end

  assign matrix_req_valid_o = req_valid_q;
  assign matrix_req_is_write_o = req_is_write_q;
  assign matrix_req_size_bytes_o = req_size_q;
  assign matrix_req_addr_o = req_addr_q;
  assign matrix_req_wdata_o = c_stage_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_valid_q <= 1'b0;
    end else begin
      if (c_write || load_read) begin
        req_valid_q <= 1'b1;
      end else if (req_fire) begin
        req_valid_q <= 1'b0;
      end
    end
  end

  // Payload: only meaningful while req_valid_q is 1, so not reset.
  always_ff @(posedge clk_i) begin
    if (c_write) begin
      req_is_write_q <= 1'b1;
      req_stream_q   <= '0;
      req_addr_q     <= c_addr_q;
      req_size_q     <= SizeW'((32'(c_slot_q) + 1) * C_ROW_BYTES);
    end else if (load_read) begin
      req_is_write_q <= 1'b0;
      req_stream_q   <= pick;
      req_addr_q     <= st_req_addr[pick];
      req_size_q     <= st_req_size[pick];
    end
  end

  // ---------------------------------------------------------------------------
  // Responses: reads in request order into their stream; write acks counted
  // ---------------------------------------------------------------------------
  assign rsp_read = matrix_rsp_valid_i && !order_empty;
  assign rsp_ack  = matrix_rsp_valid_i && order_empty;

  bpu_sa_fifo #(
    .Width(2),
    .Depth(NUM_STREAMS * BufRows)
  ) u_order (
    .clk_i,
    .rst_ni,
    .push_i (req_fire && !req_is_write_q),
    .data_i (req_stream_q),
    .pop_i  (rsp_read),
    .data_o (order_head),
    .empty_o(order_empty),
    .full_o (order_full)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      acks_left_q <= '0;
    end else begin
      if (WriteAcks && req_fire && req_is_write_q && !rsp_ack) begin
        acks_left_q <= acks_left_q + 1'b1;
      end else if (WriteAcks && rsp_ack && !(req_fire && req_is_write_q)) begin
        acks_left_q <= acks_left_q - 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Feed: one array step per cycle from the head rows of A and B
  // ---------------------------------------------------------------------------
  assign feed_valid = busy_q && !feed_done_q && !st_empty[S_A] && !st_empty[S_B];
  assign feed_final = (k_q == k_last_q);
  assign feed_first = scaled_q ? (bstep_q == '0) : (k_q == '0);
  assign feed_last = scaled_q ? (bstep_q == bstep_last_q) : feed_final;
  assign feed_fire = feed_valid && sa_in_ready;
  // A head rows are used up after their last step, or after the command's last.
  assign st_pop[S_A] = feed_fire && (feed_final || a_slot_q == a_slot_last_q);
  assign st_pop[S_B] = feed_fire && (feed_final || b_slot_q == B_SLOT_WIDTH'(B_STEPS - 1));

  // The A bytes of this step: Rows (INT8) or 2 * Rows (INT4) from the head row,
  // zero-padded so the window never runs past the row.
  assign a_head_ext = {{A_WIN_BITS{1'b0}}, st_head[S_A]};
  assign a_win = a_head_ext[32'(a_slot_q)*(int4_q?16*Rows : 8*Rows)+:A_WIN_BITS];
  assign b_win = st_head[S_B][32'(b_slot_q)*(8*Cols)+:8*Cols];

  for (genvar i = 0; i < Rows; i++) begin : g_a_lane
    if (Int4) begin : g_int4
      // INT4 pair: A[i][k] low, A[i][k+1] high (zero past an odd K).
      assign sa_in_a[A_LANE*i+:A_LANE] = int4_q
          ? {(feed_final && odd_q) ? 8'h00 : a_win[8*(Rows+i)+:8], a_win[8*i+:8]}
          : {8'h00, a_win[8*i+:8]};
    end else begin : g_int8
      assign sa_in_a[A_LANE*i+:A_LANE] = a_win[8*i+:8];
    end
  end

  for (genvar j = 0; j < Cols; j++) begin : g_b_lane
    if (Int4) begin : g_int4
      // INT4 pair: nibble j of row k (first Cols/2 bytes) low, of row k+1 high.
      assign sa_in_b[8*j+:8] = int4_q ? {b_win[4*Cols+4*j+:4], b_win[4*j+:4]} : b_win[8*j+:8];
    end else begin : g_int8
      assign sa_in_b[8*j+:8] = b_win[8*j+:8];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      k_q         <= '0;
      bstep_q     <= '0;
      a_slot_q    <= '0;
      b_slot_q    <= '0;
      feed_done_q <= 1'b0;
    end else begin
      if (cmd_fire) begin
        k_q         <= '0;
        bstep_q     <= '0;
        a_slot_q    <= '0;
        b_slot_q    <= '0;
        feed_done_q <= 1'b0;
      end else if (feed_fire) begin
        k_q <= k_q + 1'b1;
        if (feed_last) begin
          bstep_q <= '0;
        end else begin
          bstep_q <= bstep_q + 1'b1;
        end
        if (st_pop[S_A]) begin
          a_slot_q <= '0;
        end else begin
          a_slot_q <= a_slot_q + 1'b1;
        end
        if (st_pop[S_B]) begin
          b_slot_q <= '0;
        end else begin
          b_slot_q <= b_slot_q + 1'b1;
        end
        if (feed_final) begin
          feed_done_q <= 1'b1;
        end
      end
    end
  end

  bpu_sa_array #(
    .Rows(Rows),
    .Cols(Cols),
    .AccW(AccW),
    .Int4(Int4)
  ) u_array (
    .clk_i,
    .rst_ni,
    .mode_i       (int4_q),
    .err_mode_o   (sa_err_mode),
    .in_valid_i   (feed_valid),
    .in_ready_o   (sa_in_ready),
    .in_a_i       (sa_in_a),
    .in_b_i       (sa_in_b),
    .in_first_i   (feed_first),
    .in_last_i    (feed_last),
    .out_valid_o  (sa_out_valid),
    .out_ready_i  (sa_out_ready),
    .out_row_o    (sa_out_row),
    .out_row_idx_o(sa_out_row_idx),
    .out_last_o   (sa_out_last)
  );

  // ---------------------------------------------------------------------------
  // Drain: rows of each tile, scaled (block-scaled) or as INT32 (unscaled)
  // ---------------------------------------------------------------------------
  // A row is taken when its block's scales are buffered and, if it is final,
  // when the write-back queue has room for it.
  assign emit = !scaled_q || (g_q == g_last_q);
  assign scales_ok = !scaled_q || (!st_empty[S_SA] && !st_empty[S_SB]);
  assign sa_out_ready = busy_q && scales_ok && (!emit || out_credit_q != '0);
  assign sa_out_fire = sa_out_valid && sa_out_ready;
  assign block_end = sa_out_fire && sa_out_last;
  assign sa_bits = st_head[S_SA][(32'(sa_slot_q)*Rows+32'(sa_out_row_idx))*16+:16];
  assign sb_bits = st_head[S_SB][32'(sb_slot_q)*(16*Cols)+:16*Cols];
  assign st_pop[S_SA] = scaled_q && block_end
      && (g_q == g_last_q || sa_slot_q == SA_SLOT_WIDTH'(SA_BLOCKS - 1));
  assign st_pop[S_SB] = scaled_q && block_end
      && (g_q == g_last_q || sb_slot_q == SB_SLOT_WIDTH'(SB_BLOCKS - 1));

  for (genvar j = 0; j < Cols; j++) begin : g_c_sext
    assign c_row32[32*j+:32] = 32'($signed(sa_out_row[AccW*j+:AccW]));
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      g_q       <= '0;
      sa_slot_q <= '0;
      sb_slot_q <= '0;
    end else begin
      if (cmd_fire) begin
        g_q       <= '0;
        sa_slot_q <= '0;
        sb_slot_q <= '0;
      end else if (block_end) begin
        g_q <= g_q + 1'b1;
        if (st_pop[S_SA]) begin
          sa_slot_q <= '0;
        end else begin
          sa_slot_q <= sa_slot_q + 1'b1;
        end
        if (st_pop[S_SB]) begin
          sb_slot_q <= '0;
        end else begin
          sb_slot_q <= sb_slot_q + 1'b1;
        end
      end
    end
  end

  if (Scale) begin : g_scale
    bpu_sa_scale_acc #(
      .Rows(Rows),
      .Cols(Cols),
      .AccW(AccW)
    ) u_scale (
      .clk_i,
      .rst_ni,
      .in_valid_i (sa_out_fire && scaled_q),
      .in_row_i   (sa_out_row),
      .in_idx_i   (sa_out_row_idx),
      .in_first_i (g_q == '0),
      .in_emit_i  (emit),
      .in_last_i  (sa_out_last),
      .in_sa_i    (sa_bits),
      .in_sb_i    (sb_bits),
      .out_valid_o(sc_valid),
      .out_row_o  (sc_row),
      .out_last_o (sc_last)
    );
  end else begin : g_no_scale
    logic unused_scale;

    assign unused_scale = ^{sa_bits, sb_bits};
    assign sc_valid     = 1'b0;
    assign sc_row       = '0;
    assign sc_last      = 1'b0;
  end

  // Finished rows: from the scale stage (block-scaled) or straight from the
  // array (unscaled). Only one command runs at a time, so they never mix.
  assign out_push = scaled_q ? sc_valid : sa_out_fire;
  assign out_data = scaled_q ? {sc_last, sc_row} : {sa_out_last, c_row32};

  bpu_sa_fifo #(
    .Width(Cols * 32 + 1),
    .Depth(OutDepth)
  ) u_out (
    .clk_i,
    .rst_ni,
    .push_i (out_push),
    .data_i (out_data),
    .pop_i  (c_pop),
    .data_o (out_head),
    .empty_o(out_empty),
    .full_o (out_full)
  );

  // Credits: a final row reserves its queue entry when the array hands it over.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_credit_q <= OUT_CREDIT_WIDTH'(OutDepth);
    end else begin
      if (sa_out_fire && emit && !c_pop) begin
        out_credit_q <= out_credit_q - 1'b1;
      end else if (c_pop && !(sa_out_fire && emit)) begin
        out_credit_q <= out_credit_q + 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // C write-back: stage rows into one SRAM row, write it when full or at the end
  // ---------------------------------------------------------------------------
  // The staging row is the write data, so it takes no row while a request is
  // pending.
  assign c_pop   = busy_q && !req_valid_q && !out_empty;
  assign c_write = c_pop && (out_head[Cols*32] || c_slot_q == C_SLOT_WIDTH'(C_ROWS_PER_WRITE - 1));

  always_ff @(posedge clk_i) begin
    if (c_pop) begin
      c_stage_q[32'(c_slot_q)*(8*C_ROW_BYTES)+:8*C_ROW_BYTES] <= out_head[Cols*32-1:0];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      c_addr_q <= '0;
      c_slot_q <= '0;
      c_done_q <= 1'b0;
    end else begin
      if (cmd_fire) begin
        c_addr_q <= cmd_c_addr_i;
        c_slot_q <= '0;
        c_done_q <= 1'b0;
      end else begin
        if (c_write) begin
          c_addr_q <= c_addr_q + AddrW'(ROW_BYTES);
          c_slot_q <= '0;
        end else if (c_pop) begin
          c_slot_q <= c_slot_q + 1'b1;
        end
        if (c_pop && out_head[Cols*32]) begin
          c_done_q <= 1'b1;
        end else if (finish) begin
          c_done_q <= 1'b0;
        end
      end
    end
  end

  // The queues' full flags are covered by credits (and checked inside
  // bpu_sa_fifo); a build without Int4 never selects the INT4 mode, so it uses
  // neither the mode error nor odd_q.
  assign unused_signals = ^{order_full, out_full, sa_err_mode, odd_q};

endmodule
