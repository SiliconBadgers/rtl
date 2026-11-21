module command_queue_tb #(
  parameter int unsigned QueueDepth = 4
);
  timeunit 1ns; timeprecision 1ps;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic push_valid;
  logic push_ready;
  logic [15:0] push_payload;
  logic [3:0] push_target_0;
  logic [3:0] push_target_1;
  logic [3:0] head_target_0;
  logic [3:0] head_target_1;
  logic dependencies_met;
  logic issue_valid;
  logic issue_ready;
  logic [15:0] issue_payload;
  logic [15:0] model_payload[QueueDepth];
  logic [3:0] model_target_0[QueueDepth];
  logic [3:0] model_target_1[QueueDepth];
  int occupancy = 0;
  bit offered = 0;
  int cycles = 0;
  int pushes = 0;
  int pops = 0;
  int simultaneous = 0;
  int full_pop = 0;
  int blocked = 0;
  int stalled = 0;
  int retained = 0;
  int reset_work = 0;
  int seed = 1;
  int unsigned random_state;
  bit missing_reset;
  bit missing_backpressure;
  bit wrong_result;
  bit pending = 0;
  bit timeout_mode = 0;

  command_queue #(
    .QueueDepth  (QueueDepth),
    .PayloadWidth(16),
    .CounterWidth(4)
  ) u_command_queue (
    .clk_i(clk),
    .rst_ni(rst_n),
    .push_valid_i(push_valid),
    .push_ready_o(push_ready),
    .push_payload_i(push_payload),
    .push_wait_target_0_i(push_target_0),
    .push_wait_target_1_i(push_target_1),
    .head_wait_target_0_o(head_target_0),
    .head_wait_target_1_o(head_target_1),
    .dependencies_met_i(dependencies_met),
    .issue_valid_o(issue_valid),
    .issue_ready_i(issue_ready),
    .issue_payload_o(issue_payload)
  );

  always #5 clk = ~clk;

  function automatic int unsigned random_word();
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
  endfunction

  task automatic check_outputs();
    bit expected_valid;
    logic [15:0] expected_payload;
    expected_valid   = rst_n && occupancy != 0 && (offered || dependencies_met);
    expected_payload = occupancy != 0 ? model_payload[0] : '0;
    if (wrong_result && occupancy != 0) begin
      expected_payload ^= 16'h0001;
    end
    if (push_ready !== (rst_n && occupancy < QueueDepth) || issue_valid !== expected_valid) begin
      $fatal(1, "queue handshake mismatch cycle=%0d occupancy=%0d", cycles, occupancy);
    end
    if (issue_payload !== expected_payload ||
        head_target_0 !== (occupancy != 0 ? model_target_0[0] : 4'b0) ||
        head_target_1 !== (occupancy != 0 ? model_target_1[0] : 4'b0)) begin
      $fatal(1, "queue data mismatch cycle=%0d occupancy=%0d", cycles, occupancy);
    end
  endtask

  // Drive on falling edges, compare before the accepting edge, then update the
  // reference queue and compare after nonblocking assignments have settled.
  task automatic cycle(input bit want_push, input bit ready, input bit dependencies);
    bit accepted;
    bit issued;
    bit was_valid;
    @(negedge clk);
    push_valid = want_push || pending;
    push_payload = 16'(pushes * 37 + 19);
    push_target_0 = 4'(pushes + 3);
    push_target_1 = 4'(pushes * 3 + 5);
    issue_ready = missing_backpressure ? 1'b1 : ready;
    dependencies_met = dependencies;
    #1;
    check_outputs();
    accepted = push_valid && push_ready;
    issued = issue_valid && issue_ready;
    was_valid = issue_valid;
    if (occupancy != 0 && !issue_valid) begin
      blocked++;
    end
    if (issue_valid && !issue_ready) begin
      stalled++;
    end
    if (issue_valid && !dependencies_met) begin
      retained++;
    end
    if (accepted && issued) begin
      simultaneous++;
    end
    if (occupancy == QueueDepth && issued) begin
      full_pop++;
    end
    @(posedge clk);
    if (issued) begin
      for (int index = 0; index < occupancy - 1; index++) begin
        model_payload[index]  = model_payload[index+1];
        model_target_0[index] = model_target_0[index+1];
        model_target_1[index] = model_target_1[index+1];
      end
      occupancy--;
      pops++;
      offered = 0;
    end else if (was_valid) begin
      offered = 1;
    end
    if (accepted) begin
      model_payload[occupancy]  = push_payload;
      model_target_0[occupancy] = push_target_0;
      model_target_1[occupancy] = push_target_1;
      occupancy++;
      pushes++;
    end
    pending = push_valid && !accepted;
    cycles++;
    #1;
    check_outputs();
  endtask

  task automatic reset_queue();
    @(negedge clk);
    reset_work += occupancy;
    rst_n = 0;
    occupancy = 0;
    offered = 0;
    pending = 0;
    push_valid = 0;
    #1;
    check_outputs();
    @(posedge clk);
    #1;
    rst_n = 1;
    #1;
    check_outputs();
  endtask

  initial begin
    push_valid = 0;
    push_payload = '0;
    push_target_0 = '0;
    push_target_1 = '0;
    issue_ready = 0;
    dependencies_met = 0;
    void'($value$plusargs("missing_reset=%d", missing_reset));
    void'($value$plusargs("missing_backpressure=%d", missing_backpressure));
    void'($value$plusargs("wrong_result=%d", wrong_result));
    if ($value$plusargs("seed=%d", seed)) begin
      random_state = unsigned'(seed);
    end else begin
      random_state = 1;
    end
    if (random_state == 0) begin
      random_state = 1;
    end
    reset_queue();
    void'($value$plusargs("timeout=%d", timeout_mode));
    if (timeout_mode) begin
      $display("TIMEOUT_ARMED");
      forever @(posedge clk);
    end
    // Fill with an ineligible head, offer it under backpressure, then revoke
    // dependency readiness to check the retained offer independently of counters.
    repeat (QueueDepth) cycle(1, 0, 0);
    cycle(1, 0, 1);
    cycle(1, 0, 0);
    cycle(1, 1, 0);
    cycle(1, 1, 1);
    repeat (QueueDepth + 1) cycle(0, 1, 1);
    // Each pass crosses the physical end of the FIFO and exercises full-pop
    // behavior. Depth one intentionally cannot push and pop simultaneously.
    repeat (4) begin
      repeat (QueueDepth) cycle(1, 0, 0);
      cycle(1, 1, 1);
      cycle(1, 1, 1);
      repeat (QueueDepth + 1) cycle(0, 1, 1);
    end
    if (QueueDepth > 1) begin
      cycle(1, 0, 0);
      repeat (12) cycle(1, 1, 1);
      repeat (QueueDepth + 1) cycle(0, 1, 1);
    end
    if (!missing_reset) begin
      repeat (QueueDepth) cycle(1, 0, 0);
      cycle(0, 0, 1);
      reset_queue();
    end
    repeat (1000) begin
      bit want_push;
      bit ready;
      bit dependencies;
      want_push = pending || (random_word() % 4 != 0);
      ready = random_word() % 3 != 0;
      dependencies = random_word() % 3 != 0;
      cycle(want_push, ready, dependencies);
    end
    if (pending) begin
      cycle(1, 1, 1);
      if (pending) begin
        cycle(1, 1, 1);
      end
    end
    repeat (QueueDepth + 1) cycle(0, 1, 1);
    if (stalled == 0) begin
      $fatal(1, "missing backpressure prerequisite");
    end
    if (reset_work == 0) begin
      $fatal(1, "missing reset prerequisite");
    end
    if (retained == 0 || blocked == 0 || full_pop == 0 ||
        (QueueDepth > 1 && simultaneous == 0) || pushes < 4 * QueueDepth || occupancy != 0) begin
      $fatal(1, "missing queue scenario");
    end
    if (pushes != pops + reset_work) begin
      $fatal(1, "queue transaction accounting mismatch");
    end
    $display({"RESULT queue depth=%0d seed=%0d cycles=%0d pushes=%0d pops=%0d ",
              "simultaneous=%0d full_pop=%0d blocked=%0d stalled=%0d retained=%0d reset_work=%0d"},
               QueueDepth, seed, cycles, pushes, pops, simultaneous, full_pop, blocked, stalled,
               retained, reset_work);
    $finish;
  end
endmodule
