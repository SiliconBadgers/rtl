module command_queues_tb #(
  parameter bit CustomMapping = 1'b0
);
  timeunit 1ns; timeprecision 1ps;
  localparam int unsigned NUM_QUEUES = CustomMapping ? 4 : 3;
  localparam int unsigned NUM_COUNTERS = CustomMapping ? 2 : 3;
  localparam int unsigned DEPTH = 3;
  typedef int signed mapping_t[NUM_QUEUES];
  function automatic mapping_t mapping(input bit second, input bit defaults);
    mapping_t result;
    for (int q = 0; q < NUM_QUEUES; q++) begin
      if (defaults) begin
        result[q] = -1;
      end else if (CustomMapping) begin
        result[q] = second ? q / 2 : q % 2;
      end else begin
        result[q] = second ? ((q == 2) ? 1 : 2) : ((q == 0) ? 1 : 0);
      end
    end
    return result;
  endfunction
  localparam mapping_t MAP_0 = mapping(1'b0, 1'b0);
  localparam mapping_t MAP_1 = mapping(1'b1, 1'b0);
  localparam mapping_t DUT_MAP_0 = mapping(1'b0, !CustomMapping);
  localparam mapping_t DUT_MAP_1 = mapping(1'b1, !CustomMapping);
  typedef struct packed {
    logic [15:0] payload;
    logic [2:0]  target_0;
    logic [2:0]  target_1;
  } entry_t;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic push_valid[NUM_QUEUES];
  logic push_ready[NUM_QUEUES];
  logic [15:0] push_payload[NUM_QUEUES];
  logic [2:0] target_0[NUM_QUEUES];
  logic [2:0] target_1[NUM_QUEUES];
  logic issue_valid[NUM_QUEUES];
  logic issue_ready[NUM_QUEUES];
  logic [15:0] issue_payload[NUM_QUEUES];
  logic [1:0] increment[NUM_COUNTERS];
  logic [2:0] progress[NUM_COUNTERS];
  entry_t expected[NUM_QUEUES][DEPTH];
  int unsigned count[NUM_QUEUES];
  int unsigned expected_progress[NUM_COUNTERS];
  bit offered[NUM_QUEUES];
  bit pushed[NUM_QUEUES];
  int unsigned checks = 0;
  int unsigned accepted = 0;
  int unsigned issued = 0;
  int unsigned stalls = 0;
  int unsigned reset_pending = 0;
  int unsigned seed = 1;
  int unsigned random_state;

  command_queues #(
    .QueueDepth(DEPTH),
    .PayloadWidth(16),
    .CounterWidth(3),
    .NumQueues(NUM_QUEUES),
    .NumCounters(NUM_COUNTERS),
    .WaitCounter0(DUT_MAP_0),
    .WaitCounter1(DUT_MAP_1)
  ) u_queues (
    .clk_i(clk),
    .rst_ni(rst_n),
    .push_valid_i(push_valid),
    .push_ready_o(push_ready),
    .push_payload_i(push_payload),
    .push_wait_target_0_i(target_0),
    .push_wait_target_1_i(target_1),
    .issue_valid_o(issue_valid),
    .issue_ready_i(issue_ready),
    .issue_payload_o(issue_payload),
    .increment_i(increment),
    .progress_o(progress)
  );
  always #5 clk = ~clk;

  function automatic bit reached(input int unsigned value, input int unsigned target);
    return target == 0 || ((value + 8 - target) % 8) < 4;
  endfunction

  function automatic bit eligible(input int q);
    return rst_n && count[q] != 0 &&
      (offered[q] || (reached(expected_progress[MAP_0[q]], int'(expected[q][0].target_0)) &&
                      reached(expected_progress[MAP_1[q]], int'(expected[q][0].target_1))));
  endfunction

  task automatic check_outputs();
    for (int q = 0; q < NUM_QUEUES; q++) begin
      if (push_ready[q] !== (rst_n && count[q] < DEPTH) || issue_valid[q] !== eligible(
          q
        ) || issue_payload[q] !== ((count[q] == 0) ? 16'b0 : expected[q][0].payload)) begin
        $fatal(1, "Wrapper mismatch q=%0d count=%0d ready=%b valid=%b payload=%h", q, count[q],
               push_ready[q], issue_valid[q], issue_payload[q]);
      end
      checks++;
    end
    for (int c = 0; c < NUM_COUNTERS; c++) begin
      if (progress[c] !== 3'(expected_progress[c])) begin
        $fatal(1, "Wrapper progress mismatch c=%0d", c);
      end
      checks++;
    end
  endtask

  task automatic step();
    bit take_push;
    bit take_issue;
    bit valid_before;
    #1;
    check_outputs();
    @(posedge clk);
    for (int q = 0; q < NUM_QUEUES; q++) begin
      take_push = push_valid[q] && count[q] < DEPTH;
      pushed[q] = take_push;
      valid_before = eligible(q);
      take_issue = valid_before && issue_ready[q];
      if (valid_before && !issue_ready[q]) begin
        stalls++;
      end
      if (take_issue) begin
        for (int slot = 0; slot < DEPTH - 1; slot++) begin
          expected[q][slot] = expected[q][slot+1];
        end
        count[q]--;
        issued++;
      end
      if (take_push) begin
        expected[q][count[q]] = '{push_payload[q], target_0[q], target_1[q]};
        count[q]++;
        accepted++;
      end
      offered[q] = !take_issue && (offered[q] || valid_before);
    end
    for (int c = 0; c < NUM_COUNTERS; c++) begin
      expected_progress[c] = (expected_progress[c] + int'(increment[c])) % 8;
    end
    #1;
    check_outputs();
    @(negedge clk);
  endtask

  task automatic reset_model();
    rst_n = 1'b0;
    count = '{default: 0};
    offered = '{default: 0};
    expected_progress = '{default: 0};
    push_valid = '{default: 0};
    increment = '{default: '0};
    #1;
    check_outputs();
    @(negedge clk);
    rst_n = 1'b1;
  endtask

  initial begin
    push_valid = '{default: 0};
    issue_ready = '{default: 0};
    push_payload = '{default: '0};
    target_0 = '{default: '0};
    target_1 = '{default: '0};
    increment = '{default: '0};
    count = '{default: 0};
    offered = '{default: 0};
    expected_progress = '{default: 0};
    if ($value$plusargs("seed=%d", seed)) begin
    end
    random_state = $urandom(seed);
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    // Queue zero blocks on two milestones while all other queues can issue.
    push_valid = '{default: 1};
    for (int q = 0; q < NUM_QUEUES; q++) begin
      push_payload[q] = 16'(q + 100);
    end
    target_0[0] = 3'd1;
    target_1[0] = 3'd2;
    step();
    push_valid = '{default: 0};
    push_valid[0] = 1'b1;
    push_payload[0] = 16'd200;
    target_0[0] = '0;
    target_1[0] = '0;
    issue_ready = '{default: 1};
    issue_ready[0] = 1'b0;
    step();
    if (issued != NUM_QUEUES - 1 || count[0] != 2 || issue_valid[0]) begin
      $fatal(1, "Queue isolation or head blocking scenario missing");
    end
    push_valid[0] = 1'b0;
    increment[MAP_0[0]] = 2'b01;
    step();
    if (issue_valid[0]) begin
      $fatal(1, "Second dependency did not block issue");
    end
    increment = '{default: '0};
    increment[MAP_1[0]] = (MAP_0[0] == MAP_1[0]) ? 2'b01 : 2'b10;
    step();
    increment = '{default: '0};
    step();
    // Advance through a full counter period while the offered command stalls.
    increment = '{default: 2'b10};
    repeat (4) step();
    increment = '{default: '0};
    issue_ready[0] = 1'b1;
    repeat (2) step();
    // Cancel accepted and offered work, then verify a clean post-reset epoch.
    push_valid = '{default: 1};
    issue_ready = '{default: 0};
    target_0 = '{default: '0};
    target_1 = '{default: '0};
    step();
    push_valid = '{default: 0};
    step();
    for (int q = 0; q < NUM_QUEUES; q++) begin
      reset_pending += count[q];
    end
    reset_model();
    for (int cycle = 0; cycle < 500; cycle++) begin
      for (int q = 0; q < NUM_QUEUES; q++) begin
        if (!push_valid[q] || pushed[q]) begin
          push_valid[q] = ($urandom_range(0, 3) != 0);
          push_payload[q] = 16'($urandom);
          target_0[q] = 3'($urandom_range(0, 7));
          // Duplicate slots must have a common reachable counter value.
          target_1[q] = (MAP_0[q] == MAP_1[q]) ? target_0[q] : 3'($urandom_range(0, 7));
        end
        issue_ready[q] = ($urandom_range(0, 2) != 0);
      end
      for (int c = 0; c < NUM_COUNTERS; c++) begin
        increment[c] = 2'($urandom_range(0, 2));
      end
      step();
    end
    // Complete pending pushes and steer each head's counters independently.
    // Lockstep increments can preserve an offset that never meets both waits.
    for (int draining_queue = 0; draining_queue < NUM_QUEUES; draining_queue++) begin
      issue_ready = '{default: 0};
      issue_ready[draining_queue] = 1'b1;
      for (int cycle = 0; cycle < 64; cycle++) begin
        for (int q = 0; q < NUM_QUEUES; q++) begin
          if (!push_valid[q] || pushed[q]) begin
            push_valid[q] = 1'b0;
          end
        end
        increment = '{default: '0};
        if (count[draining_queue] != 0) begin
          if (expected[draining_queue][0].target_0 != 0 &&
              expected_progress[MAP_0[draining_queue]] !=
              int'(expected[draining_queue][0].target_0)) begin
            increment[MAP_0[draining_queue]] = 2'b01;
          end
          if (expected[draining_queue][0].target_1 != 0 &&
              expected_progress[MAP_1[draining_queue]] !=
              int'(expected[draining_queue][0].target_1)) begin
            increment[MAP_1[draining_queue]] = 2'b01;
          end
        end
        step();
      end
      if (count[draining_queue] != 0 || push_valid[draining_queue]) begin
        $fatal(1, "Wrapper did not drain queue %0d", draining_queue);
      end
    end
    if (reset_pending == 0 || stalls == 0 || accepted != issued + reset_pending) begin
      $fatal(1, "Required wrapper scenario or accounting missing");
    end
    $display("SUMMARY wrapper checks=%0d accepted=%0d issued=%0d stalls=%0d reset_pending=%0d",
             checks, accepted, issued, stalls, reset_pending);
    $display("PASS command_queues_tb");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "Wrapper watchdog timeout");
  end
endmodule
