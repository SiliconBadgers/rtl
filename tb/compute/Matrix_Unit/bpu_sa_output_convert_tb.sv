// Self-checking testbench for bpu_sa_output_convert against golden vectors
// (bpu_sa_convert_vectors_pkg, written by the verification repository's
// models/golden_kquant/tools/export_convert_vectors.py from golden/matrix_v1.py).
//
// Each vector is one element: its native form (integer sum or Q23.24 code with NaN
// and overflow flags), the output encoding with its fractional bits, multiplier and
// shift, and the expected element. The converter runs with Lanes lanes; the vectors
// go through them in turn, Lanes per row, one row per cycle, back to back, so a
// stage-1 register that mixed rows would show. Checks: every element bit-exact, and
// the bytes above the element's width zero; out_valid_o one cycle after in_valid_i.
// Plusargs:
//   +seed=<n>       picks the starting vector (rotation), so seeds differ
//   +inject_error=1 corrupt one expected element on purpose; the run must FAIL
// The run ends with $fatal(1, ...) on any error and prints one RESULT line.
module bpu_sa_output_convert_tb;
  timeunit 1ns; timeprecision 1ps;
  import bpu_sa_pkg::*;
  import bpu_sa_convert_vectors_pkg::*;

  parameter int Lanes = 1;
  parameter int Seed = 1;

  logic                        clk;
  logic                        rst_n;
  logic                        in_valid;
  logic                        in_scaled;
  logic  [       Lanes*32-1:0] in_int;
  logic  [Lanes*FX_PACK_W-1:0] in_fx;
  logic  [                2:0] fmt;
  logic  [                5:0] frac;
  logic  [               31:0] mul;
  logic  [                6:0] shift;
  logic                        out_valid;
  logic  [       Lanes*32-1:0] out;

  int                          seed;
  int                          inject_arg;
  int                          errors;
  int                          checked;
  int                          per_fmt    [5];
  string                       status;

  bpu_sa_output_convert #(
    .Lanes(Lanes),
    .AccW (32)
  ) u_dut (
    .clk_i      (clk),
    .rst_ni     (rst_n),
    .in_valid_i (in_valid),
    .in_scaled_i(in_scaled),
    .in_int_i   (in_int),
    .in_fx_i    (in_fx),
    .fmt_i      (fmt),
    .frac_i     (frac),
    .mul_i      (mul),
    .shift_i    (shift),
    .out_valid_o(out_valid),
    .out_o      (out)
  );

  initial begin : clock
    clk = 1'b0;
    forever begin
      #5 clk = ~clk;
    end
  end

  // The format fields belong to a whole row, so every lane of a row carries the same
  // vector. Stage 2 reads fmt_i and shift_i combinationally, so they change only
  // after the row in the register has been checked, as in the wrapper, where they
  // hold for a whole command.
  initial begin : main
    cv_vector_t        v;
    cv_vector_t        prev;
    int                first;
    logic       [31:0] want;
    logic       [31:0] mask;

    if (!$value$plusargs("seed=%d", seed)) begin
      seed = Seed;
    end
    if (!$value$plusargs("inject_error=%d", inject_arg)) begin
      inject_arg = 0;
    end
    errors    = 0;
    checked   = 0;
    per_fmt   = '{default: 0};
    first     = (seed * 7919) % CV_COUNT;
    rst_n     = 1'b0;
    in_valid  = 1'b0;
    in_scaled = 1'b0;
    in_int    = '0;
    in_fx     = '0;
    fmt       = '0;
    frac      = '0;
    mul       = '0;
    shift     = '0;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;

    for (int n = 0; n <= CV_COUNT; n++) begin
      // Drive vector n (if any) and check vector n - 1, whose result is now out.
      @(negedge clk);
      if (n > 0) begin
        if (out_valid !== 1'b1) begin
          errors++;
          $display("bpu_sa_output_convert_tb: out_valid_o low for vector %0d", n - 1);
        end
        want = prev.expected;
        if (inject_arg != 0 && n == 1) begin
          want = want ^ 32'h1;
        end
        for (int j = 0; j < Lanes; j++) begin
          if (out[32*j+:32] !== want) begin
            errors++;
            if (errors <= 10) begin
              $display("bpu_sa_output_convert_tb: vector %0d lane %0d (scaled %b nan %b ovf %b %s",
                       n - 1, j, prev.scaled, prev.nan, prev.ovf,
                       $sformatf("value %h fmt %0d frac %0d mul %h shift %0d): got %h want %h",
                                 prev.value, prev.fmt, prev.frac, prev.mul, prev.shift,
                                 out[32*j+:32], want));
            end
          end
        end
        checked++;
        per_fmt[prev.fmt]++;
      end
      if (n == CV_COUNT) begin
        in_valid = 1'b0;
        break;
      end
      v         = CV_VECTORS[(first+n)%CV_COUNT];
      in_valid  = 1'b1;
      in_scaled = v.scaled;
      for (int j = 0; j < Lanes; j++) begin
        in_int[32*j+:32]              = v.value[31:0];
        in_fx[FX_PACK_W*j+:FX_PACK_W] = {v.nan, v.ovf, v.value};
      end
      fmt   = v.fmt;
      frac  = v.frac;
      mul   = v.mul;
      shift = v.shift;
      prev  = v;
    end
    @(negedge clk);
    if (out_valid !== 1'b0) begin
      errors++;
      $display("bpu_sa_output_convert_tb: out_valid_o high with nothing taken");
    end

    if (errors != 0 || checked != CV_COUNT || per_fmt[0] == 0 || per_fmt[1] == 0
        || per_fmt[2] == 0 || per_fmt[3] == 0 || per_fmt[4] == 0) begin
      status = "FAIL";
    end else begin
      status = "PASS";
    end
    $write("RESULT bpu_sa_output_convert_tb lanes=%0d seed=%0d checked=%0d", Lanes, seed, checked);
    $display(" legacy=%0d int32=%0d fp32=%0d fp16=%0d int8=%0d errors=%0d status=%s", per_fmt[0],
             per_fmt[1], per_fmt[2], per_fmt[3], per_fmt[4], errors, status);
    if (status != "PASS") begin
      $fatal(1, "bpu_sa_output_convert_tb: FAIL (%0d errors)", errors);
    end
    $finish;
  end

endmodule
