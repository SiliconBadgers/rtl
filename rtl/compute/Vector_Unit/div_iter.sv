// Sequential unsigned divider: restoring shift-subtract, one quotient bit per cycle.
// (Binary long division, as described in https://projectf.io/posts/division-in-verilog/)
//
// Each cycle shifts the next dividend bit into the accumulator. If the accumulator is
// then at least the divisor, the divisor is subtracted and a 1 enters the quotient,
// otherwise a 0. Before the shift the accumulator is below the divisor, so one
// subtraction per step is enough.
//
// iterations: how many low dividend bits are significant (1..WIDTH). The dividend is
// pre-shifted so leading zero bits are skipped: a 32-bit divide takes 32 cycles.
// The caller handles a zero divisor (the quotient is then all ones).
//
// start (one cycle) -> busy for `iterations` cycles -> finished stays high, with
// quotient and remainder held, until the next start.
module div_iter #(
  parameter int Width = 64
) (
  input  logic                       clk_i,
  input  logic                       rst_ni,
  input  logic                       start_i,
  input  logic [$clog2(Width+1)-1:0] iterations_i,
  input  logic [Width-1:0]           dividend_i,
  input  logic [Width-1:0]           divisor_i,
  output logic                       busy_o,
  output logic                       finished_o,
  output logic [Width-1:0]           quotient_o,
  output logic [Width-1:0]           remainder_o
);
  localparam int CW = $clog2(Width+1);

  logic [Width:0]   acc;             // partial remainder, one bit wider than the divisor
  logic [Width-1:0] quo;             // remaining dividend bits shift out on the left,
                                     // quotient bits shift in on the right
  logic [Width-1:0] div_reg;
  logic [CW-1:0]    count;

  logic [Width:0]   acc_shifted;
  logic             fits;

  assign acc_shifted = {acc[Width-1:0], quo[Width-1]};
  assign fits        = (acc_shifted >= {1'b0, div_reg});

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      acc <= '0;
      quo <= '0;
      div_reg <= '0;
      count <= '0;
      busy_o <= 1'b0;
      finished_o <= 1'b0;
    end else if (start_i) begin
      acc <= '0;
      quo <= dividend_i << (Width[CW-1:0] - iterations_i);
      div_reg <= divisor_i;
      count <= iterations_i;
      busy_o <= (iterations_i != 0);
      finished_o <= (iterations_i == 0);
    end else if (busy_o) begin
      if (fits) begin
        acc <= acc_shifted - {1'b0, div_reg};
        quo <= {quo[Width-2:0], 1'b1};
      end else begin
        acc <= acc_shifted;
        quo <= {quo[Width-2:0], 1'b0};
      end

      count <= count - 1'b1;
      if (count == 1) begin
        busy_o <= 1'b0;
        finished_o <= 1'b1;
      end
    end
  end

  assign quotient_o  = quo;
  assign remainder_o = acc[Width-1:0];

endmodule
