// Block 1: fixed priority winner selection
// current logic is -  Mem manager > Matrix > Vec[lowest index]
// Purely combinational
module sram_arb_priority
  import sram_arbiter_pkg::*;
(
  input  logic                 mm_valid_i,
  input  logic                 matrix_valid_i,
  input  logic [NUM_LANES-1:0] vec_valid_i,
  output logic                 grant_valid_o,
  output logic                 grant_mm_o,
  output logic                 grant_matrix_o,
  output logic [NUM_LANES-1:0] grant_vec_o,
  output req_tag_e             grant_idx_o
);

  logic [NUM_LANES-1:0]     vec_first;      // lowest-index valid lane
  logic [LANE_IDX_BITS-1:0] vec_first_idx;

  // Isolate the lowest set bit of vec_valid_i, then encode its index.
  assign vec_first = vec_valid_i & (~vec_valid_i + NUM_LANES'(1));

  always_comb begin
    vec_first_idx = '0;
    for (int unsigned lane = 0; lane < NUM_LANES; lane++) begin
      if (vec_first[lane]) begin
        vec_first_idx = LANE_IDX_BITS'(lane);
      end
    end
  end

  always_comb begin
    grant_mm_o     = 1'b0;
    grant_matrix_o = 1'b0;
    grant_vec_o    = '0;
    grant_idx_o    = TagMm;

    if (mm_valid_i) begin
      grant_mm_o  = 1'b1;
      grant_idx_o = TagMm;
    end else if (matrix_valid_i) begin
      grant_matrix_o = 1'b1;
      grant_idx_o    = TagMatrix;
    end else if (vec_valid_i != '0) begin
      grant_vec_o = vec_first;
      grant_idx_o = vec_lane_tag(vec_first_idx);
    end
  end

  assign grant_valid_o = mm_valid_i | matrix_valid_i | (|vec_valid_i);

endmodule
