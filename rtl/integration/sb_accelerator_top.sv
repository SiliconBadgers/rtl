// One in-flight command. This integration stub does not implement rtl-control#5.
module sb_accelerator_top (
  input logic clk_i,
  input logic rst_ni,
  input logic quiesce_i,
  output logic idle_o,
  input logic cmd_valid_i,
  output logic cmd_ready_o,
  input sb_types_pkg::command_t cmd_i,
  output logic completion_valid_o,
  input logic completion_ready_i,
  output sb_types_pkg::completion_t completion_o
);
  import sb_types_pkg::*;
  logic busy_q;
  engine_e active_q, selected;
  logic [4:0] request_valid, request_ready, response_valid, response_ready;
  completion_t responses [5];
  assign selected = cmd_i.abi == 16'd1 ? target_engine(cmd_i.opcode) : EngineInvalid;
  assign idle_o = !busy_q;
  assign cmd_ready_o = !busy_q && !quiesce_i && request_ready[selected];
  assign completion_valid_o = busy_q && response_valid[active_q];
  assign completion_o = busy_q ? responses[active_q] : '0;
  always_comb begin
    request_valid = '0;
    response_ready = '0;
    if (!busy_q && !quiesce_i) request_valid[selected] = cmd_valid_i;
    if (busy_q) response_ready[active_q] = completion_ready_i;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q <= 1'b0;
      active_q <= EngineInvalid;
    end else begin
      if (cmd_valid_i && cmd_ready_o) begin
        busy_q <= 1'b1;
        active_q <= selected;
      end
      if (completion_valid_o && completion_ready_i) busy_q <= 1'b0;
    end
  end
  // Named instances establish team boundaries without implementing their internals.
  sb_engine_stub matrix_engine (.clk_i, .rst_ni, .cmd_i,
    .cmd_valid_i(request_valid[0]), .cmd_ready_o(request_ready[0]),
    .completion_valid_o(response_valid[0]), .completion_ready_i(response_ready[0]), .completion_o(responses[0]));
  sb_engine_stub vector_engine (.clk_i, .rst_ni, .cmd_i,
    .cmd_valid_i(request_valid[1]), .cmd_ready_o(request_ready[1]),
    .completion_valid_o(response_valid[1]), .completion_ready_i(response_ready[1]), .completion_o(responses[1]));
  sb_engine_stub state_manager (.clk_i, .rst_ni, .cmd_i,
    .cmd_valid_i(request_valid[2]), .cmd_ready_o(request_ready[2]),
    .completion_valid_o(response_valid[2]), .completion_ready_i(response_ready[2]), .completion_o(responses[2]));
  sb_engine_stub memory_subsystem (.clk_i, .rst_ni, .cmd_i,
    .cmd_valid_i(request_valid[3]), .cmd_ready_o(request_ready[3]),
    .completion_valid_o(response_valid[3]), .completion_ready_i(response_ready[3]), .completion_o(responses[3]));
  sb_engine_stub #(.ReturnStatus(StatusBadCommand)) invalid_command (.clk_i, .rst_ni, .cmd_i,
    .cmd_valid_i(request_valid[4]), .cmd_ready_o(request_ready[4]),
    .completion_valid_o(response_valid[4]), .completion_ready_i(response_ready[4]), .completion_o(responses[4]));
  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(request_valid));
  assert property (@(posedge clk_i) disable iff (!rst_ni) busy_q |-> !cmd_ready_o);
endmodule
