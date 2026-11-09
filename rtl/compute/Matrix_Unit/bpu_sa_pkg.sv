// Constants of the Matrix Unit shared by bpu_sa_pe, bpu_sa_array, bpu_sa_sram_wrapper
// and bpu_sa_command_decoder: the block-scaled numerics (the full contract is in
// docs/compute/matrix_unit_io_scheme.md, Arithmetic), the output encodings and the
// version-1 command record (docs/compute/matrix_unit_spec.md).
package bpu_sa_pkg;

  // Not every importer uses every constant.
  /* verilator lint_off UNUSEDPARAM */

  // The scaled accumulator in each PE: signed fixed point, FX_W bits with FX_FRAC
  // fractional bits (Q23.24): it holds integer / 2^FX_FRAC.
  localparam int unsigned FX_W = 48;
  localparam int unsigned FX_FRAC = 24;

  // A drained block-scaled result: {nan, overflow, value}.
  localparam int unsigned FX_PACK_W = FX_W + 2;

  // Cycles from the edge that takes a block's last k-step into a PE to the edge that
  // updates the PE's scaled accumulator (and, for a tile's final block, its shadow).
  localparam int unsigned SCALE_PIPE = 4;

  // A bf16 scale is (-1)^s * m * 2^(e - 127 - 7) with m = {1, mantissa} (8 bits), so
  //   isum * sa * sb * 2^FX_FRAC = isum * ma * mb * 2^(ea + eb - SCALE_SHIFT_BIAS).
  localparam int unsigned SCALE_SHIFT_BIAS = 2 * (127 + 7) - FX_FRAC;

  // The version-1 Matrix command record (docs/compute/matrix_unit_spec.md,
  // "Command record"): 16 little-endian 32-bit words, word w in bits [32w+31:32w].
  localparam int unsigned RECORD_W = 512;
  localparam logic [1:0] RECORD_KIND_MATRIX = 2'd1;
  localparam logic [7:0] RECORD_VERSION = 8'd1;

  // Output encodings (cmd_out_format_i, record word 9 bits 24:22).
  localparam logic [2:0] OUT_LEGACY = 3'd0;  // INT32 integer commands, FP32 scaled
  localparam logic [2:0] OUT_INT32 = 3'd1;  // saturate32(RNE(v * 2^frac))
  localparam logic [2:0] OUT_FP32 = 3'd2;
  localparam logic [2:0] OUT_FP16 = 3'd3;
  localparam logic [2:0] OUT_INT8 = 3'd4;  // clamp(RNE(a * mul / 2^shift), -127, 127)

  /* verilator lint_on UNUSEDPARAM */

  // A decoded record. Addresses are bytes; m, n, k as the wrapper's cmd_*_i.
  typedef struct packed {
    logic [31:0] mem_wait;       // Memory progress target
    logic [31:0] vec_wait;       // Vector progress target
    logic [31:0] a_addr;
    logic [31:0] b_addr;
    logic [31:0] c_addr;
    logic [31:0] sa_addr;
    logic [31:0] sb_addr;
    logic [15:0] m;
    logic [15:0] n;
    logic [15:0] k;
    logic        trans_a;        // always 0 in an accepted version-1 record
    logic        trans_b;
    logic        clear_acc;
    logic        write_output;
    logic        int4;
    logic        scaled;
    logic [2:0]  out_format;
    logic [5:0]  out_frac;
    logic [31:0] requant_mul;
    logic [6:0]  requant_shift;
  } matrix_command_t;

  // --- Output conversion (bpu_sa_output_convert; also the wrapper TB's reference) ---
  // frac is checked to be at most 31 by the wrapper, so its top bit is unused here;
  // each conversion reads only the fields of cv_mid_t it needs.
  /* verilator lint_off UNUSEDSIGNAL */

  localparam int unsigned CV_MSB_W = $clog2(FX_W);  // a bit index into a magnitude
  localparam int unsigned CV_PROD_W = FX_W + 32;  // magnitude times a 32-bit multiplier

  // One element after stage 1: its native value as sign and magnitude, the
  // magnitude's leading one, and its product with the INT8 multiplier (2^frac for
  // INT32). Integer sums arrive sign-extended to 32 bits and are exact here.
  typedef struct packed {
    logic                 scaled;
    logic                 nan;
    logic                 ovf;
    logic                 neg;
    logic                 zero;
    logic [FX_W-1:0]      mag;
    logic [CV_MSB_W-1:0]  msb;
    logic [CV_PROD_W-1:0] prod;
  } cv_mid_t;

  // The position of the highest 1 in x (0 when x is 0), in log depth: smear the
  // leading 1 into every lower bit, keep the top of the smear, encode its index.
  function automatic logic [CV_MSB_W-1:0] cv_lead(input logic [FX_W-1:0] x);
    logic [    FX_W-1:0] smear;
    logic [    FX_W-1:0] onehot;
    logic [CV_MSB_W-1:0] idx;
    smear = x;
    for (int d = 1; d < FX_W; d = 2 * d) begin
      smear = smear | (smear >> d);
    end
    onehot = smear & ~(smear >> 1);
    idx    = '0;
    for (int b = 0; b < FX_W; b++) begin
      if (onehot[b]) begin
        idx = idx | CV_MSB_W'(b);
      end
    end
    return idx;
  endfunction

  // The p-bit significand of mag, whose leading 1 is at msb, rounded to nearest even.
  // Rounding can carry to 2^p (bit p set).
  function automatic logic [24:0] cv_round_sig(input logic [FX_W-1:0] mag,
                                               input logic [CV_MSB_W-1:0] msb, input int p);
    logic [FX_W-1:0] q;
    logic [FX_W-1:0] rem;
    logic [FX_W-1:0] half;
    int              sh;
    sh = int'(msb) - (p - 1);
    if (sh <= 0) begin
      return 25'(mag << (-sh));
    end
    q    = mag >> sh;
    rem  = mag & ((FX_W'(1) << sh) - 1'b1);
    half = FX_W'(1) << (sh - 1);
    if (rem > half || (rem == half && q[0])) begin
      q = q + 1'b1;
    end
    return 25'(q);
  endfunction

  function automatic cv_mid_t cv_stage1(input logic scaled, input logic [31:0] int_val,
                                        input logic [FX_PACK_W-1:0] fx, input logic [2:0] fmt,
                                        input logic [5:0] frac, input logic [31:0] mul);
    cv_mid_t            m;
    logic    [FX_W-1:0] v;
    logic    [    31:0] k;
    k        = (fmt == OUT_INT32) ? (32'd1 << frac[4:0]) : mul;
    v        = scaled ? fx[FX_W-1:0] : FX_W'($signed(int_val));
    m.scaled = scaled;
    m.nan    = scaled && fx[FX_W+1];
    m.ovf    = scaled && fx[FX_W];
    m.neg    = v[FX_W-1];
    m.mag    = m.neg ? FX_W'(-v) : v;  // -2^47 gives 2^47, still exact unsigned
    m.zero   = (v == '0);
    m.msb    = cv_lead(m.mag);
    m.prod   = CV_PROD_W'(m.mag) * CV_PROD_W'(k);
    return m;
  endfunction

  // IEEE binary32 of the element: value mag * 2^-frac_bits, nearest even (always
  // normal here: |v| is at least 2^-24 and below 2^32).
  function automatic logic [31:0] cv_fp32(input cv_mid_t m);
    logic [24:0] sig;
    int          e;
    if (m.nan) begin
      return 32'h7fc0_0000;
    end
    if (m.ovf) begin
      return {m.neg, 8'hff, 23'h0};
    end
    if (m.zero) begin
      return 32'h0;
    end
    e   = int'(m.msb) - (m.scaled ? int'(FX_FRAC) : 0);
    sig = cv_round_sig(m.mag, m.msb, 24);
    if (sig[24]) begin
      e = e + 1;
    end
    return {m.neg, 8'(e + 127), sig[24] ? 23'h0 : sig[22:0]};
  endfunction

  // IEEE binary16, nearest even, rounded directly from the native value. Subnormals:
  // only a block-scaled |v| below 2^-14, i.e. |a| below 2^10, whose code is then
  // exactly the subnormal significand (both count units of 2^-24).
  function automatic logic [15:0] cv_fp16(input cv_mid_t m);
    logic [24:0] sig;
    int          e;
    if (m.nan) begin
      return 16'h7e00;
    end
    if (m.ovf) begin
      return {m.neg, 5'h1f, 10'h0};
    end
    if (m.zero) begin
      return 16'h0;
    end
    e = int'(m.msb) - (m.scaled ? int'(FX_FRAC) : 0);
    if (e < -14) begin
      return {m.neg, 5'h00, m.mag[9:0]};
    end
    sig = cv_round_sig(m.mag, m.msb, 11);
    if (sig[11]) begin
      e = e + 1;
    end
    if (e > 15) begin
      return {m.neg, 5'h1f, 10'h0};
    end
    return {m.neg, 5'(e + 15), sig[11] ? 10'h0 : sig[9:0]};
  endfunction

  // INT32 fixed point and INT8: RNE(prod / 2^sh), then saturation. INT32 shifts out
  // the native fractional bits (prod = mag * 2^frac); INT8 the command's shift.
  function automatic logic [31:0] cv_fixed(input cv_mid_t m, input logic is_int8,
                                           input logic [6:0] shift);
    logic [127:0] w;
    logic [127:0] q;
    logic [127:0] rest;
    int           sh;
    w  = 128'(m.prod);
    sh = is_int8 ? int'(shift) : (m.scaled ? int'(FX_FRAC) : 0);
    q  = w >> sh;
    if (sh > 0) begin
      rest = w & ((128'd1 << sh) - 1'b1);
      if (rest > (128'd1 << (sh - 1)) || (rest == (128'd1 << (sh - 1)) && q[0])) begin
        q = q + 1'b1;
      end
    end
    if (m.nan) begin
      return 32'h0;
    end
    if (is_int8) begin
      if (m.ovf || q > 128'd127) begin
        return {24'h0, m.neg ? 8'h81 : 8'h7f};
      end
      return {24'h0, m.neg ? 8'(-q[7:0]) : q[7:0]};
    end
    if (m.ovf) begin
      return m.neg ? 32'h8000_0000 : 32'h7fff_ffff;
    end
    if (!m.neg) begin
      return (q > 128'h7fff_ffff) ? 32'h7fff_ffff : q[31:0];
    end
    return (q > 128'h8000_0000) ? 32'h8000_0000 : 32'(-q[31:0]);
  endfunction

  // Stage 2: the element in encoding fmt, in the low bytes of 32 bits.
  function automatic logic [31:0] cv_stage2(input cv_mid_t m, input logic [2:0] fmt,
                                            input logic [6:0] shift);
    case (fmt)
      OUT_LEGACY: return m.scaled ? cv_fp32(m) : (m.neg ? 32'(-m.mag) : 32'(m.mag));
      OUT_INT32:  return cv_fixed(m, 1'b0, shift);
      OUT_FP32:   return cv_fp32(m);
      OUT_FP16:   return {16'h0, cv_fp16(m)};
      OUT_INT8:   return cv_fixed(m, 1'b1, shift);
      default:    return 32'h0;
    endcase
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

endpackage
