// One outstanding command. Execution endpoints are connected by the parent.
module command_router (
  input logic clk_i,
  input logic rst_ni,
  input logic quiesce_i,
  output logic idle_o,
  input logic cmd_valid_i,
  output logic cmd_ready_o,
  input command_pkg::command_t cmd_i,
  output logic completion_valid_o,
  input logic completion_ready_i,
  output command_pkg::completion_t completion_o,
  output logic [command_pkg::NUM_ROUTES-1:0] request_valid_o,
  input logic [command_pkg::NUM_ROUTES-1:0] request_ready_i,
  input logic [command_pkg::NUM_ROUTES-1:0] response_valid_i,
  output logic [command_pkg::NUM_ROUTES-1:0] response_ready_o,
  input command_pkg::completion_t responses_i[command_pkg::NUM_ROUTES]
);
  import command_pkg::*;

  logic   busy_q;
  route_e active_q;
  route_e selected;

  always_comb begin
    selected = RouteInvalid;
    if (cmd_i.abi_version == COMMAND_ABI_VERSION) begin
      selected = decode_route(cmd_i.opcode);
    end
  end

  assign idle_o = !busy_q;
  assign cmd_ready_o = !busy_q && !quiesce_i && request_ready_i[selected];
  assign completion_valid_o = busy_q && response_valid_i[active_q];
  assign completion_o = busy_q ? responses_i[active_q] : '0;

  always_comb begin
    request_valid_o  = '0;
    response_ready_o = '0;
    if (!busy_q && !quiesce_i) begin
      request_valid_o[selected] = cmd_valid_i;
    end
    if (busy_q) begin
      response_ready_o[active_q] = completion_ready_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q   <= 1'b0;
      active_q <= RouteInvalid;
    end else if (cmd_valid_i && cmd_ready_o) begin
      busy_q   <= 1'b1;
      active_q <= selected;
    end else if (completion_valid_o && completion_ready_i) begin
      busy_q <= 1'b0;
    end
  end

  RequestOnehot_A :
  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(request_valid_o));
  BusyBlocksCommand_A :
  assert property (@(posedge clk_i) disable iff (!rst_ni) busy_q |-> !cmd_ready_o);
  CompletionOwned_A :
  assert property (@(posedge clk_i) disable iff (!rst_ni) completion_valid_o |-> busy_q);
  property route_held_p;
    @(posedge clk_i) disable iff (!rst_ni)
    busy_q && !(completion_valid_o && completion_ready_i) |=> $stable(
      active_q
    );
  endproperty
  RouteHeld_A :
  assert property (route_held_p);

  property completion_stable_p;
    @(posedge clk_i) disable iff (!rst_ni)
    completion_valid_o && !completion_ready_i
    |=> completion_valid_o && $stable(
      completion_o
    );
  endproperty
  CompletionStable_A :
  assert property (completion_stable_p);
endmodule
