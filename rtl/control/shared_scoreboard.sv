// Configurable milestone counters and exactly two comparisons per queue head.
// Increments are encoded counts per counter: 00=0, 01=1, 10=2; 11 is illegal.
// Event ordering and exactly-once publication are responsibilities of producers.
module shared_scoreboard #(
  parameter int unsigned CounterWidth = 16,
  parameter int unsigned NumQueues = 3,
  parameter int unsigned NumCounters = 3,
  parameter int WaitCounter0 [NumQueues] = '{default: -1},
  parameter int WaitCounter1 [NumQueues] = '{default: -1}
) (
  input logic clk_i,
  input logic rst_ni,
  input logic [1:0] increment_i [NumCounters],
  input logic [CounterWidth-1:0] wait_target_0_i [NumQueues],
  input logic [CounterWidth-1:0] wait_target_1_i [NumQueues],
  output logic dependencies_met_o [NumQueues],
  output logic [CounterWidth-1:0] progress_o [NumCounters]
);
  localparam int MEMORY_INDEX = 0;
  localparam int MATRIX_INDEX = 1;
  localparam int VECTOR_INDEX = 2;

  logic [CounterWidth-1:0] progress_q [NumCounters];

  // Truncate subtraction to exactly CounterWidth bits before testing its MSB.
  // Software must keep live dependencies within half the counter range.
  function automatic logic target_reached(
    input logic [CounterWidth-1:0] progress,
    input logic [CounterWidth-1:0] target
  );
    logic [CounterWidth-1:0] delta;
    delta = progress - target;
    return (target == '0) || !delta[CounterWidth-1];
  endfunction

  // The illegal encoding holds the affected counter in hardware; simulation
  // assertions report the protocol error. No saturation or overflow flag exists.
  function automatic logic [CounterWidth-1:0] advance_progress(
    input logic [CounterWidth-1:0] progress,
    input logic [1:0] increment
  );
    case (increment)
      2'b00: return progress;
      2'b01: return progress + CounterWidth'(1);
      2'b10: return progress + CounterWidth'(2);
      default: return progress;
    endcase
  endfunction

  for (genvar counter_index = 0; counter_index < NumCounters;
       counter_index++) begin : gen_counters
    assign progress_o[counter_index] = progress_q[counter_index];

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        progress_q[counter_index] <= '0;
      end else begin
        progress_q[counter_index] <= advance_progress(
            progress_q[counter_index], increment_i[counter_index]);
      end
    end

    IncrementLegal_A: assert property (
      @(posedge clk_i) disable iff (!rst_ni)
      increment_i[counter_index] inside {2'b00, 2'b01, 2'b10}
    ) else $fatal(1, "Illegal milestone increment for counter %0d", counter_index);
  end

  for (genvar queue_index = 0; queue_index < NumQueues; queue_index++) begin : gen_dependencies
    // Preserve the original Memory/Matrix/Vector mapping only for queues 0..2.
    // No dependency graph is inferred for additional queues.
    localparam int LEGACY_COUNTER_0 =
        (queue_index == MEMORY_INDEX) ? MATRIX_INDEX :
        ((queue_index == MATRIX_INDEX) || (queue_index == VECTOR_INDEX)) ? MEMORY_INDEX : -1;
    localparam int LEGACY_COUNTER_1 =
        (queue_index == VECTOR_INDEX) ? MATRIX_INDEX :
        ((queue_index == MEMORY_INDEX) || (queue_index == MATRIX_INDEX)) ? VECTOR_INDEX : -1;
    localparam int COUNTER_0 =
        (WaitCounter0[queue_index] == -1) ? LEGACY_COUNTER_0 : WaitCounter0[queue_index];
    localparam int COUNTER_1 =
        (WaitCounter1[queue_index] == -1) ? LEGACY_COUNTER_1 : WaitCounter1[queue_index];
    localparam bit MAPPING_VALID =
        (COUNTER_0 >= 0) && (COUNTER_0 < NumCounters) &&
        (COUNTER_1 >= 0) && (COUNTER_1 < NumCounters);

    if (MAPPING_VALID) begin : gen_valid_mapping
      // Registered progress only: there is no same-cycle increment bypass.
      assign dependencies_met_o[queue_index] =
          target_reached(progress_q[COUNTER_0], wait_target_0_i[queue_index]) &&
          target_reached(progress_q[COUNTER_1], wait_target_1_i[queue_index]);
    end else begin : gen_invalid_mapping
      // Avoid out-of-range references even in a rejected configuration.
      assign dependencies_met_o[queue_index] = 1'b0;
      initial begin
        WaitMappingValid_A: assert (MAPPING_VALID)
          else $fatal(1, "Set valid WaitCounter0/1 indices for queue %0d", queue_index);
      end
    end
  end

  initial begin
    CounterWidthValid_A: assert (CounterWidth > 0)
      else $fatal(1, "CounterWidth must be positive");
    NumQueuesValid_A: assert (NumQueues > 0)
      else $fatal(1, "NumQueues must be positive");
    NumCountersValid_A: assert (NumCounters > 0)
      else $fatal(1, "NumCounters must be positive");
  end
endmodule
