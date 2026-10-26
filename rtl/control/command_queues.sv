// Independent ordered FIFOs connected to one shared, configurable scoreboard.
// Inputs are already routed command fields; this is not a binary-ABI decoder.
module command_queues #(
  parameter int unsigned QueueDepth = 4,
  parameter int unsigned PayloadWidth = 32,
  parameter int unsigned CounterWidth = 16,
  parameter int unsigned NumQueues = 3,
  parameter int unsigned NumCounters = 3,
  // -1 selects the legacy mapping for queues 0..2. Additional queues must map
  // both slots explicitly; each command still carries exactly two wait targets.
  parameter int WaitCounter0 [NumQueues] = '{default: -1},
  parameter int WaitCounter1 [NumQueues] = '{default: -1}
) (
  input logic clk_i,
  input logic rst_ni,
  input logic push_valid_i [NumQueues],
  output logic push_ready_o [NumQueues],
  input logic [PayloadWidth-1:0] push_payload_i [NumQueues],
  input logic [CounterWidth-1:0] push_wait_target_0_i [NumQueues],
  input logic [CounterWidth-1:0] push_wait_target_1_i [NumQueues],
  output logic issue_valid_o [NumQueues],
  input logic issue_ready_i [NumQueues],
  output logic [PayloadWidth-1:0] issue_payload_o [NumQueues],
  input logic [1:0] increment_i [NumCounters],
  output logic [CounterWidth-1:0] progress_o [NumCounters]
);
  logic [CounterWidth-1:0] head_wait_target_0 [NumQueues];
  logic [CounterWidth-1:0] head_wait_target_1 [NumQueues];
  logic dependencies_met [NumQueues];

  for (genvar queue_index = 0; queue_index < NumQueues; queue_index++) begin : gen_queues
    command_queue #(
      .QueueDepth(QueueDepth),
      .PayloadWidth(PayloadWidth),
      .CounterWidth(CounterWidth)
    ) u_command_queue (
      .clk_i,
      .rst_ni,
      .push_valid_i(push_valid_i[queue_index]),
      .push_ready_o(push_ready_o[queue_index]),
      .push_payload_i(push_payload_i[queue_index]),
      .push_wait_target_0_i(push_wait_target_0_i[queue_index]),
      .push_wait_target_1_i(push_wait_target_1_i[queue_index]),
      .head_wait_target_0_o(head_wait_target_0[queue_index]),
      .head_wait_target_1_o(head_wait_target_1[queue_index]),
      .dependencies_met_i(dependencies_met[queue_index]),
      .issue_valid_o(issue_valid_o[queue_index]),
      .issue_ready_i(issue_ready_i[queue_index]),
      .issue_payload_o(issue_payload_o[queue_index])
    );
  end

  shared_scoreboard #(
    .CounterWidth(CounterWidth),
    .NumQueues(NumQueues),
    .NumCounters(NumCounters),
    .WaitCounter0(WaitCounter0),
    .WaitCounter1(WaitCounter1)
  ) u_shared_scoreboard (
    .clk_i,
    .rst_ni,
    .increment_i,
    .wait_target_0_i(head_wait_target_0),
    .wait_target_1_i(head_wait_target_1),
    .dependencies_met_o(dependencies_met),
    .progress_o
  );
endmodule
