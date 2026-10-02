// INT8 MAC PE: acc += a * b (signed), 32-bit accumulate.
`timescale 1ns / 1ps

module pe_mac (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               clear,
  input  logic               enable,
  input  logic signed [ 7:0] a,
  input  logic signed [ 7:0] b,
  output logic signed [31:0] acc
);
  logic signed [15:0] prod;
  assign prod = a * b;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) acc <= '0;
    else if (clear) acc <= '0;
    else if (enable) acc <= acc + {{16{prod[15]}}, prod};
  end
endmodule
