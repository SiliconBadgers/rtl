// Sequential reciprocal square root D = 1/sqrt(A) for an F32 input, rounded once to
// F16 and to F32 (nearest, ties to even). F16 inputs are widened exactly by the caller.
//
// With A = m * 2^(2k) (m an integer significand, exponent made even):
//   1/sqrt(A) = (2^N / sqrt(m)) * 2^(-N-k)
// r = floor(2^N / sqrt(m)) is the largest integer with r*r*m <= 2^(2N). It is found
// one bit per cycle, high bit first: keep a trial bit if trial*trial*m <= 2^(2N).
// No division is needed. The result is exact only when r*r*m == 2^(2N); otherwise the
// sticky bit is set, so the single rounding is correct.
//
// m is in [2^23, 2^25), so r is in (2^26.5, 2^27.5]: 28 root bits, 28 cycles.
// a must stay stable from start until finished.
// error: A is NaN/Inf, zero (either sign), or negative.
module fp_rsqrt (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        start_i,
  input  logic [31:0] a_i,
  output logic        busy_o,
  output logic        finished_o,
  output logic [15:0] d16_o,
  output logic        error16_o,
  output logic [31:0] d32_o,
  output logic        error32_o
);
  localparam int N         = 39;           // r has at least 26 = FracBits+3 bits for F32
  localparam int ROOT_BITS = 28;

  localparam logic [80:0] TARGET = 81'd1 << (2 * N);

  logic [7:0]  exp_a;
  logic [23:0] sig_a;
  logic [24:0] m;
  integer      msb, e_a;
  logic        input_error;

  logic [ROOT_BITS-1:0] root, trial;
  logic [80:0]          product;
  logic                 exact;
  logic [4:0]           bit_index;

  logic overflow16, overflow32;

  // Normalize A and make its exponent even (combinational from the held input).
  always_comb begin
    exp_a = a_i[30:23];
    sig_a = {(exp_a != 0), a_i[22:0]};
    e_a = ((exp_a == 0) ? 1 : int'(exp_a)) - 150;              // A = sig_a * 2^e_a

    msb = 0;
    for (int i = 0; i < 24; i++) begin
      if (sig_a[i]) begin
        msb = i;
      end
    end
    m = {1'b0, sig_a} << (23 - msb);
    e_a = e_a - (23 - msb);

    if (e_a[0]) begin
      m = m << 1;
      e_a = e_a - 1;
    end

    input_error = (&exp_a) || (sig_a == 0) || a_i[31];
  end

  // Trial: the current root with the next bit set.
  assign trial   = root | ({{(ROOT_BITS-1){1'b0}}, 1'b1} << bit_index);
  assign product = 81'(trial) * 81'(trial) * 81'(m);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      root <= '0;
      exact <= 1'b0;
      bit_index <= '0;
      busy_o <= 1'b0;
      finished_o <= 1'b0;
    end else if (start_i) begin
      root <= '0;
      exact <= 1'b0;
      bit_index <= 5'(ROOT_BITS - 1);
      busy_o <= 1'b1;
      finished_o <= 1'b0;
    end else if (busy_o) begin
      if (product <= TARGET) begin
        root <= trial;
        exact <= (product == TARGET);
      end

      if (bit_index == 0) begin
        busy_o <= 1'b0;
        finished_o <= 1'b1;
      end else begin
        bit_index <= bit_index - 1'b1;
      end
    end
  end

  fp_round #(.ExpBits(5), .FracBits(10)) u_round_f16 (
    .sign_i(1'b0),
    .mag_i(64'(root)),
    .exponent_i(-N - (e_a >>> 1)),
    .sticky_i(!exact),
    .d_o(d16_o),
    .overflow_o(overflow16)
  );

  fp_round #(.ExpBits(8), .FracBits(23)) u_round_f32 (
    .sign_i(1'b0),
    .mag_i(64'(root)),
    .exponent_i(-N - (e_a >>> 1)),
    .sticky_i(!exact),
    .d_o(d32_o),
    .overflow_o(overflow32)
  );

  assign error16_o = input_error || overflow16;
  assign error32_o = input_error || overflow32;

endmodule
