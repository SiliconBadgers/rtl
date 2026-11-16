module shared_scoreboard_tb #(
  parameter bit CustomMapping  = 1'b0,
  parameter bit InvalidMapping = 1'b0
);
  timeunit 1ns; timeprecision 1ps;
  localparam int unsigned NUM_QUEUES = CustomMapping ? 4 : 3;
  localparam int unsigned NUM_COUNTERS = CustomMapping ? 2 : 3;
  localparam int unsigned COUNTER_WIDTH = 3;
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
  localparam mapping_t DUT_MAP_0 = InvalidMapping ? '{default: -2} : mapping(1'b0, !CustomMapping);
  localparam mapping_t DUT_MAP_1 = mapping(1'b1, !CustomMapping);
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [1:0] increment[NUM_COUNTERS];
  logic [COUNTER_WIDTH-1:0] target_0[NUM_QUEUES];
  logic [COUNTER_WIDTH-1:0] target_1[NUM_QUEUES];
  logic dependencies_met[NUM_QUEUES];
  logic [COUNTER_WIDTH-1:0] progress[NUM_COUNTERS];
  int unsigned expected_progress[NUM_COUNTERS];
  int illegal_increment = 0;
  int unknown_increment = 0;
  int unsigned comparisons = 0;
  int unsigned counter_checks = 0;
  int unsigned wraps = 0;
  int unsigned increment_counts[3] = '{default: 0};

  shared_scoreboard #(
    .CounterWidth(COUNTER_WIDTH),
    .NumQueues(NUM_QUEUES),
    .NumCounters(NUM_COUNTERS),
    .WaitCounter0(DUT_MAP_0),
    .WaitCounter1(DUT_MAP_1)
  ) u_scoreboard (
    .clk_i(clk),
    .rst_ni(rst_n),
    .increment_i(increment),
    .wait_target_0_i(target_0),
    .wait_target_1_i(target_1),
    .dependencies_met_o(dependencies_met),
    .progress_o(progress)
  );

  always #5 clk = ~clk;

  function automatic bit reached(input int unsigned value, input int unsigned target);
    return target == 0 || ((value + 8 - target) % 8) < 4;
  endfunction

  task automatic check_outputs();
    for (int c = 0; c < NUM_COUNTERS; c++) begin
      if (progress[c] !== COUNTER_WIDTH'(expected_progress[c])) begin
        $fatal(1, "Counter mismatch c=%0d expected=%0d actual=%0d", c, expected_progress[c],
               progress[c]);
      end
      counter_checks++;
    end
    for (int q = 0; q < NUM_QUEUES; q++) begin
      if (dependencies_met[q] !== (reached(
          expected_progress[MAP_0[q]], int'(target_0[q])
        ) && reached(
          expected_progress[MAP_1[q]], int'(target_1[q])
        ))) begin
        $fatal(1, "Dependency mismatch q=%0d targets=%0d,%0d", q, target_0[q], target_1[q]);
      end
      comparisons++;
    end
  endtask

  task automatic step();
    // Check before the active edge to reject a combinational increment bypass.
    #1;
    check_outputs();
    @(posedge clk);
    for (int c = 0; c < NUM_COUNTERS; c++) begin
      increment_counts[int'(increment[c])]++;
      if (expected_progress[c] + int'(increment[c]) >= 8) begin
        wraps++;
      end
      expected_progress[c] = (expected_progress[c] + int'(increment[c])) % 8;
    end
    #1;
    check_outputs();
    @(negedge clk);
  endtask

  initial begin
    increment = '{default: '0};
    target_0 = '{default: '0};
    target_1 = '{default: '0};
    expected_progress = '{default: 0};
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    if ($value$plusargs("illegal_increment=%d", illegal_increment) && illegal_increment != 0) begin
      increment[0] = 2'b11;
      repeat (2) @(negedge clk);
      $fatal(1, "Illegal increment was not rejected");
    end
    if ($value$plusargs("unknown_increment=%d", unknown_increment) && unknown_increment != 0) begin
      increment[0] = 2'bx1;
      repeat (2) @(negedge clk);
      $fatal(1, "Unknown increment was not rejected");
    end
    // Every progress value is paired with every combination of the two targets.
    // Distinct counter offsets make an incorrect static mapping observable.
    for (int c = 0; c < NUM_COUNTERS; c++) begin
      for (int n = 0; n < c; n++) begin
        increment[c] = 2'b01;
        step();
      end
      increment[c] = '0;
    end
    for (int p = 0; p < 8; p++) begin
      for (int a = 0; a < 8; a++) begin
        for (int b = 0; b < 8; b++) begin
          for (int q = 0; q < NUM_QUEUES; q++) begin
            target_0[q] = COUNTER_WIDTH'(a);
            target_1[q] = COUNTER_WIDTH'(b);
          end
          step();
        end
      end
      increment = '{default: 2'b01};
      step();
      increment = '{default: '0};
    end
    for (int pattern = 0; pattern < 27; pattern++) begin
      for (int c = 0; c < NUM_COUNTERS; c++) begin
        increment[c] = 2'((pattern / (3 ** c)) % 3);
      end
      step();
    end
    increment = '{default: '0};
    rst_n = 1'b0;
    expected_progress = '{default: 0};
    #1;
    check_outputs();
    @(negedge clk);
    rst_n = 1'b1;
    step();
    if (wraps == 0 || increment_counts[0] == 0 || increment_counts[1] == 0 ||
        increment_counts[2] == 0) begin
      $fatal(1, "Required scoreboard scenario missing");
    end
    $display(
      "SUMMARY scoreboard comparisons=%0d counter_checks=%0d wraps=%0d inc0=%0d inc1=%0d inc2=%0d",
      comparisons, counter_checks, wraps, increment_counts[0], increment_counts[1],
      increment_counts[2]);
    $display("PASS shared_scoreboard_tb");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "Scoreboard watchdog timeout");
  end
endmodule
