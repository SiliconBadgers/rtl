// A non-fallthrough FIFO with dependency-gated issue of its head command.
// See docs/control/command-queues.md for handshake, reset and integration rules.
module command_queue #(
  parameter int unsigned QueueDepth = 4,
  parameter int unsigned PayloadWidth = 32,
  parameter int unsigned CounterWidth = 16
) (
  input logic clk_i,
  input logic rst_ni,
  input logic push_valid_i,
  output logic push_ready_o,
  input logic [PayloadWidth-1:0] push_payload_i,
  input logic [CounterWidth-1:0] push_wait_target_0_i,
  input logic [CounterWidth-1:0] push_wait_target_1_i,
  output logic [CounterWidth-1:0] head_wait_target_0_o,
  output logic [CounterWidth-1:0] head_wait_target_1_o,
  input logic dependencies_met_i,
  output logic issue_valid_o,
  input logic issue_ready_i,
  output logic [PayloadWidth-1:0] issue_payload_o
);
  localparam int unsigned POINTER_WIDTH = (QueueDepth > 1) ? $clog2(QueueDepth) : 1;
  localparam int unsigned COUNT_WIDTH = (QueueDepth > 0) ? $clog2(QueueDepth + 1) : 1;

  logic [PayloadWidth-1:0] payload_q [QueueDepth];
  logic [CounterWidth-1:0] wait_target_0_q [QueueDepth];
  logic [CounterWidth-1:0] wait_target_1_q [QueueDepth];
  logic [POINTER_WIDTH-1:0] read_pointer_q;
  logic [POINTER_WIDTH-1:0] write_pointer_q;
  logic [COUNT_WIDTH-1:0] count_q;
  logic offered_q;
  logic nonempty;
  logic push;
  logic pop;

  function automatic logic [POINTER_WIDTH-1:0] next_pointer(
    input logic [POINTER_WIDTH-1:0] pointer
  );
    if (pointer == POINTER_WIDTH'(QueueDepth - 1)) begin
      return '0;
    end
    return pointer + POINTER_WIDTH'(1);
  endfunction

  assign nonempty = (count_q != '0);
  // Conservative full behavior avoids a combinational issue-ready to push-ready
  // path. A full queue that pops accepts a new command on the following cycle.
  assign push_ready_o = rst_ni && (count_q < COUNT_WIDTH'(QueueDepth));
  assign issue_valid_o = rst_ni && nonempty && (offered_q || dependencies_met_i);
  assign issue_payload_o = nonempty ? payload_q[read_pointer_q] : '0;
  assign head_wait_target_0_o = nonempty ? wait_target_0_q[read_pointer_q] : '0;
  assign head_wait_target_1_o = nonempty ? wait_target_1_q[read_pointer_q] : '0;
  assign push = push_valid_i && push_ready_o;
  assign pop = issue_valid_o && issue_ready_i;

  // Payload storage does not need reset: count and pointers invalidate all slots.
  always_ff @(posedge clk_i) begin
    if (push) begin
      payload_q[write_pointer_q] <= push_payload_i;
      wait_target_0_q[write_pointer_q] <= push_wait_target_0_i;
      wait_target_1_q[write_pointer_q] <= push_wait_target_1_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_pointer_q <= '0;
      write_pointer_q <= '0;
      count_q <= '0;
      offered_q <= 1'b0;
    end else begin
      if (push) begin
        write_pointer_q <= next_pointer(write_pointer_q);
      end
      if (pop) begin
        read_pointer_q <= next_pointer(read_pointer_q);
      end
      case ({push, pop})
        2'b10: count_q <= count_q + COUNT_WIDTH'(1);
        2'b01: count_q <= count_q - COUNT_WIDTH'(1);
        default: count_q <= count_q;
      endcase
      // Once valid has been offered, advancing or wrapping other counters must
      // not retract it while the consumer is stalled. Only pop/reset clears it.
      if (pop) begin
        offered_q <= 1'b0;
      end else if (issue_valid_o) begin
        offered_q <= 1'b1;
      end
    end
  end

  initial begin
    QueueDepthValid_A: assert (QueueDepth > 0)
      else $fatal(1, "QueueDepth must be positive");
    PayloadWidthValid_A: assert (PayloadWidth > 0)
      else $fatal(1, "PayloadWidth must be positive");
    CounterWidthValid_A: assert (CounterWidth > 0)
      else $fatal(1, "CounterWidth must be positive");
  end

  OccupancyBounded_A: assert property (
    @(posedge clk_i) disable iff (!rst_ni) count_q <= COUNT_WIDTH'(QueueDepth)
  ) else $fatal(1, "Command queue overflow");
  ReadPointerBounded_A: assert property (
    @(posedge clk_i) disable iff (!rst_ni) int'(read_pointer_q) < QueueDepth
  ) else $fatal(1, "Command queue read pointer out of range");
  WritePointerBounded_A: assert property (
    @(posedge clk_i) disable iff (!rst_ni) int'(write_pointer_q) < QueueDepth
  ) else $fatal(1, "Command queue write pointer out of range");
  IssueStable_A: assert property (
    @(posedge clk_i) disable iff (!rst_ni)
    issue_valid_o && !issue_ready_i |=> issue_valid_o && $stable(issue_payload_o) &&
        $stable(head_wait_target_0_o) && $stable(head_wait_target_1_o)
  ) else $fatal(1, "Stalled command queue issue changed");
endmodule
