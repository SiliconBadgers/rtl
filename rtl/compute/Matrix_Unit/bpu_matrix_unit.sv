// The Matrix unit as the top-level controller instantiates it: one port for the
// Matrix command queue, one for the sram_arbiter Matrix channel, and the three
// signals the controller reads (progress, idle, fault). Inside, the version-1 record
// decoder feeds the SRAM wrapper, which runs one command at a time (CmdDepth = 1).
// The contract is docs/compute/matrix_unit_integration.md.
//
// Sources: rtl/compute/Matrix_Unit/bpu_sa_array.f (this module is listed last).
//
// ---------------------------------------------------------------------------------
// Connections
//
//   Command  cmd_valid_i / cmd_ready_o / cmd_payload_i connect to the command queues'
//            Matrix issue port (issue_valid_o[1], issue_ready_i[1],
//            issue_payload_o[1]). The payload is the 512-bit version-1 record
//            (docs/compute/matrix_unit_spec.md, "Command record") in bits 511:0;
//            any bit above 511 of a wider system payload must be zero.
//            cmd_ready_o depends only on registers, so the queue may hold valid
//            and the payload stable for as long as it likes. The record's two
//            wait-target words are ignored: the controller checks its own sideband
//            copies before the command reaches this port.
//   Progress milestone_inc_o connects to increment_i[1]: three milestones per
//            accepted legal command, in order (inputs released; next contribution
//            ready; complete), 00 / 01 / 10 per cycle, never 11.
//   Idle     idle_o connects to engine_idle_i[1]. High when no command is running
//            and no milestone is held or on milestone_inc_o, so every accepted
//            command's C writes have committed and its milestones have all been
//            counted. Depends only on registers; high in reset.
//   Fault    fault_o connects to engine_fault_i[1]. It rises in the cycle after an
//            illegal command is accepted and stays high until reset; from then on
//            cmd_ready_o is low, so a command the queue is still offering is never
//            accepted. An illegal command touches no memory and publishes no
//            milestones. Illegal: a malformed record (bpu_sa_command_decoder), a
//            nonzero bit above 511, or anything bpu_sa_sram_wrapper rejects (shape,
//            alignment, a feature the build lacks, a continuation that does not
//            match the kept sums). Faults from the arbiter are the arbiter's own
//            fault_o, not this one.
//   SRAM     matrix_req_* / matrix_rsp_* connect to the sram_arbiter Matrix channel
//            (docs/memory/sram_arbiter_spec.md). Ordinary reads and writes only:
//            matrix_req_transpose_o and matrix_req_element_width_o are always zero
//            (transpose is not in version 1). Reads may complete any number of
//            cycles after acceptance, in order; a write accepted on edge n must be
//            committed by edge n + 1, which bpu_sa_sram_wrapper relies on for
//            idle_o.
//
// Clock and reset: one rising-edge clock. rst_ni asserts asynchronously and must be
// released synchronously. Reset the command queues, the scoreboard counter and the
// arbiter with this unit (the controller's coordinated reset): reset cancels a running
// command, discards kept sums and clears the fault, and a read response still in
// flight must be dropped by the arbiter.
// ---------------------------------------------------------------------------------
module bpu_matrix_unit
  import bpu_sa_pkg::*;
#(
  parameter int unsigned PayloadWidth = RECORD_W,  // queue payload, >= 512, whole 32-bit words
  parameter int unsigned Rows         = 8,         // the array and wrapper; see bpu_sa_sram_wrapper
  parameter int unsigned Cols         = 8,
  parameter int unsigned AccW         = 32,
  parameter int unsigned DataW        = 4096,      // sram_arbiter_pkg DATA_WIDTH
  parameter int unsigned SizeW        = 10,        // sram_arbiter_pkg SIZE_WIDTH
  parameter int unsigned BufRows      = 2,
  parameter bit          Int4         = 1'b1,
  parameter bit          Scale        = 1'b1,
  parameter int unsigned BlockK       = 16,
  parameter int unsigned OutDepth     = 9
) (
  input logic clk_i,
  input logic rst_ni,

  // Matrix command queue issue port
  input  logic                    cmd_valid_i,
  output logic                    cmd_ready_o,
  input  logic [PayloadWidth-1:0] cmd_payload_i,

  // To the controller
  output logic [1:0] milestone_inc_o,
  output logic       idle_o,
  output logic       fault_o,

  // sram_arbiter Matrix channel
  output logic             matrix_req_valid_o,
  input  logic             matrix_req_ready_i,
  output logic             matrix_req_is_write_o,
  output logic [SizeW-1:0] matrix_req_size_bytes_o,
  output logic [     31:0] matrix_req_addr_o,
  output logic [DataW-1:0] matrix_req_wdata_o,
  output logic             matrix_req_transpose_o,
  output logic [      1:0] matrix_req_element_width_o,
  input  logic             matrix_rsp_valid_i,
  input  logic [DataW-1:0] matrix_rsp_rdata_i
);

  localparam int unsigned ADDR_WIDTH = 32;  // the record's address words and the arbiter's
  localparam int unsigned K_WIDTH = 16;  // the record's K field

  matrix_command_t cmd;
  logic            dec_valid;
  logic            dec_error;
  logic            high_bits_set;
  logic            wrap_valid;
  logic            wrap_ready;
  logic            wrap_err;
  logic            fault_q;
  logic            fault;
  // The wrapper's busy and done stay inside: milestones and idle are the contract.
  logic            wrap_busy;
  logic            wrap_done;
  // Also unused: the record's wait targets (the controller checks its own copies) and
  // transpose bits (the decoder rejects them).
  logic            unused_signals;

`ifndef SYNTHESIS
  initial begin
    if (PayloadWidth < RECORD_W || (PayloadWidth % 32) != 0) begin
      $fatal(1, "bpu_matrix_unit: PayloadWidth = %0d must be a multiple of 32, at least %0d",
             PayloadWidth, RECORD_W);
    end
  end

  // The controller contract. All of these are 0 or 1 from reset on.
  always @(posedge clk_i) begin
    FaultBlocksAccept_A :
    assert (!(fault === 1'b1 && cmd_ready_o === 1'b1))
    else $error("bpu_matrix_unit: cmd_ready_o high while faulted");
    FaultStopsRequests_A :
    assert (!(fault === 1'b1 && matrix_req_valid_o === 1'b1))
    else $error("bpu_matrix_unit: SRAM request while faulted");
    IdleNoMilestone_A :
    assert (!(idle_o === 1'b1 && milestone_inc_o !== 2'b00))
    else $error("bpu_matrix_unit: milestone published while idle");
  end
`endif

  if (PayloadWidth > RECORD_W) begin : g_high_bits
    assign high_bits_set = |cmd_payload_i[PayloadWidth-1:RECORD_W];
  end else begin : g_no_high_bits
    assign high_bits_set = 1'b0;
  end

  // A fault blocks acceptance from the cycle the wrapper reports it (err_o), then the
  // sticky register holds it. Both are registers, so cmd_ready_o still depends only on
  // registers.
  assign fault = fault_q || wrap_err;
  assign fault_o = fault;
  assign wrap_valid = dec_valid && !fault;

  bpu_sa_command_decoder u_decoder (
    .rec_valid_i       (cmd_valid_i),
    .rec_ready_o       (cmd_ready_o),
    .rec_i             (cmd_payload_i[RECORD_W-1:0]),
    .cmd_valid_o       (dec_valid),
    .cmd_ready_i       (wrap_ready && !fault),
    .cmd_o             (cmd),
    .cmd_decode_error_o(dec_error)
  );

  bpu_sa_sram_wrapper #(
    .Rows    (Rows),
    .Cols    (Cols),
    .AccW    (AccW),
    .AddrW   (ADDR_WIDTH),
    .DataW   (DataW),
    .SizeW   (SizeW),
    .KW      (K_WIDTH),
    .BufRows (BufRows),
    .Int4    (Int4),
    .Scale   (Scale),
    .BlockK  (BlockK),
    .OutDepth(OutDepth)
  ) u_wrapper (
    .clk_i,
    .rst_ni,
    .cmd_valid_i        (wrap_valid),
    .cmd_ready_o        (wrap_ready),
    .cmd_a_addr_i       (cmd.a_addr),
    .cmd_b_addr_i       (cmd.b_addr),
    .cmd_c_addr_i       (cmd.c_addr),
    .cmd_sa_addr_i      (cmd.sa_addr),
    .cmd_sb_addr_i      (cmd.sb_addr),
    .cmd_m_i            (cmd.m),
    .cmd_n_i            (cmd.n),
    .cmd_k_i            (cmd.k),
    .cmd_int4_i         (cmd.int4),
    .cmd_scaled_i       (cmd.scaled),
    .cmd_clear_acc_i    (cmd.clear_acc),
    .cmd_write_output_i (cmd.write_output),
    .cmd_out_format_i   (cmd.out_format),
    .cmd_out_frac_i     (cmd.out_frac),
    .cmd_requant_mul_i  (cmd.requant_mul),
    .cmd_requant_shift_i(cmd.requant_shift),
    .cmd_decode_error_i (dec_error || high_bits_set),
    .busy_o             (wrap_busy),
    .done_o             (wrap_done),
    .err_o              (wrap_err),
    .milestone_inc_o,
    .idle_o,
    .matrix_req_valid_o,
    .matrix_req_ready_i,
    .matrix_req_is_write_o,
    .matrix_req_size_bytes_o,
    .matrix_req_addr_o,
    .matrix_req_wdata_o,
    .matrix_rsp_valid_i,
    .matrix_rsp_rdata_i
  );

  assign matrix_req_transpose_o = 1'b0;
  assign matrix_req_element_width_o = 2'b00;
  assign unused_signals = ^{wrap_busy, wrap_done, cmd.mem_wait, cmd.vec_wait, cmd.trans_a,
                            cmd.trans_b};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fault_q <= 1'b0;
    end else if (wrap_err) begin
      fault_q <= 1'b1;
    end
  end

endmodule
