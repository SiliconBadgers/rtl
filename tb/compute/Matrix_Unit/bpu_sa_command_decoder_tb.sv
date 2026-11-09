// Self-checking testbench for bpu_sa_command_decoder, the version-1 Matrix record
// decoder. The decoder is combinational, so every check applies a record and reads
// the outputs after a delay; there is no clock.
//
// The reference is written from the spec's record table, independently of the
// decoder: an encoder that places each field (encode), and a mask of every reserved
// bit (RESERVED). Expected malformed = kind != 1, version != 1, a reserved bit set,
// output format > 4, fractional bits > 31, or a transpose bit set.
//
// Phases
//   1. random legal records (Records of them): every field round-trips, no error.
//   2. directed malformed records: each kind and version other than 1, formats 5
//      to 7, fractional bits 32 and 63, each transpose bit, and every reserved bit
//      on its own (all of them, one record each).
//   3. random records with random bit flips: the error flag against the reference.
//   4. ready/valid pass straight through, both ways, for all four combinations.
// Plusargs:
//   +seed=<n>       random seed (default: Seed)
//   +inject_error=1 corrupt one expected field on purpose; the run must FAIL
// The run ends with $fatal(1, ...) on any error and prints one RESULT line.
module bpu_sa_command_decoder_tb;
  timeunit 1ns; timeprecision 1ps;
  import bpu_sa_pkg::*;

  parameter int Records = 2000;
  parameter int Seed = 1;

  logic                           rec_valid;
  logic                           rec_ready;
  logic            [RECORD_W-1:0] rec;
  logic                           cmd_valid;
  logic                           cmd_ready;
  matrix_command_t                cmd;
  logic                           bad;

  int                             seed;
  int unsigned                    rng_state;
  bit                             inject_error;
  int                             inject_arg;
  bit                             injected;
  int                             errors;
  int                             legal_checked;
  int                             malformed_checked;
  int                             reserved_bits;
  int                             flips_checked;
  int                             flips_malformed;
  string                          status;
  logic            [RECORD_W-1:0] reserved_mask;

  bpu_sa_command_decoder u_dut (
    .rec_valid_i       (rec_valid),
    .rec_ready_o       (rec_ready),
    .rec_i             (rec),
    .cmd_valid_o       (cmd_valid),
    .cmd_ready_i       (cmd_ready),
    .cmd_o             (cmd),
    .cmd_decode_error_o(bad)
  );

  // xorshift32, seeded from +seed.
  function automatic int unsigned rand32();
    rng_state = rng_state ^ (rng_state << 13);
    rng_state = rng_state ^ (rng_state >> 17);
    rng_state = rng_state ^ (rng_state << 5);
    return rng_state;
  endfunction

  // The spec's record table: word w occupies bits [32w+31 : 32w].
  function automatic logic [RECORD_W-1:0] encode(input matrix_command_t c, input logic [1:0] kind,
                                                 input logic [7:0] version);
    logic [RECORD_W-1:0] r;
    r = '0;
    r[1:0] = kind;
    r[15:8] = version;
    r[32*1+:32] = c.mem_wait;
    r[32*2+:32] = c.vec_wait;
    r[32*3+:32] = c.a_addr;
    r[32*4+:32] = c.b_addr;
    r[32*5+:32] = c.c_addr;
    r[32*6+:32] = c.sa_addr;
    r[32*7+:32] = c.sb_addr;
    r[32*8+:16] = c.m;
    r[32*8+16+:16] = c.n;
    r[32*9+:16] = c.k;
    r[32*9+16] = c.trans_a;
    r[32*9+17] = c.trans_b;
    r[32*9+18] = c.clear_acc;
    r[32*9+19] = c.write_output;
    r[32*9+20] = c.int4;
    r[32*9+21] = c.scaled;
    r[32*9+22+:3] = c.out_format;
    r[32*9+25+:6] = c.out_frac;
    r[32*10+:32] = c.requant_mul;
    r[32*11+:7] = c.requant_shift;
    return r;
  endfunction

  function automatic logic [RECORD_W-1:0] make_reserved_mask();
    logic [RECORD_W-1:0] r;
    r = '0;
    r[7:2] = '1;
    r[31:16] = '1;
    r[32*9+31] = 1'b1;
    r[32*11+7+:25] = '1;
    r[RECORD_W-1:32*12] = '1;
    return r;
  endfunction

  // A legal command with every field random (format 0..4, frac 0..31, no transpose).
  function automatic matrix_command_t rand_command();
    matrix_command_t c;
    c.mem_wait      = rand32();
    c.vec_wait      = rand32();
    c.a_addr        = rand32();
    c.b_addr        = rand32();
    c.c_addr        = rand32();
    c.sa_addr       = rand32();
    c.sb_addr       = rand32();
    c.m             = 16'(rand32());
    c.n             = 16'(rand32());
    c.k             = 16'(rand32());
    c.trans_a       = 1'b0;
    c.trans_b       = 1'b0;
    c.clear_acc     = rand32() % 2 == 1;
    c.write_output  = rand32() % 2 == 1;
    c.int4          = rand32() % 2 == 1;
    c.scaled        = rand32() % 2 == 1;
    c.out_format    = 3'(rand32() % 5);
    c.out_frac      = 6'(rand32() % 32);
    c.requant_mul   = rand32();
    c.requant_shift = 7'(rand32());
    return c;
  endfunction

  function automatic bit ref_malformed(input logic [RECORD_W-1:0] r);
    return r[1:0] != 2'd1 || r[15:8] != 8'd1 || (r & reserved_mask) != '0
        || r[32*9+22+:3] > 3'd4 || r[32*9+30] || r[32*9+16] || r[32*9+17];
  endfunction

  task automatic apply(input logic [RECORD_W-1:0] r);
    rec = r;
    #1;
  endtask

  task automatic expect_fields(input matrix_command_t want, input string what);
    if (inject_error && !injected) begin
      want.k   = want.k ^ 16'h1;
      injected = 1'b1;
    end
    if (cmd !== want) begin
      errors++;
      if (errors <= 10) begin
        $display("bpu_sa_command_decoder_tb: %s: fields %h, want %h", what, cmd, want);
      end
    end
  endtask

  task automatic expect_bad(input bit want, input string what);
    if (bad !== want) begin
      errors++;
      if (errors <= 10) begin
        $display("bpu_sa_command_decoder_tb: %s: cmd_decode_error_o = %b, want %b", what, bad,
                 want);
      end
    end
  endtask

  initial begin : main
    matrix_command_t                c;
    logic            [RECORD_W-1:0] r;
    bit                             want;

    if (!$value$plusargs("seed=%d", seed)) begin
      seed = Seed;
    end
    if (!$value$plusargs("inject_error=%d", inject_arg)) begin
      inject_arg = 0;
    end
    inject_error      = (inject_arg != 0);
    injected          = 1'b0;
    errors            = 0;
    legal_checked     = 0;
    malformed_checked = 0;
    reserved_bits     = 0;
    flips_checked     = 0;
    flips_malformed   = 0;
    rng_state         = seed ^ 32'h9e37_79b9;
    if (rng_state == 0) begin
      rng_state = 1;
    end
    reserved_mask = make_reserved_mask();
    rec_valid     = 1'b0;
    cmd_ready     = 1'b0;

    // 1. random legal records
    for (int n = 0; n < Records; n++) begin
      c = rand_command();
      apply(encode(c, 2'd1, 8'd1));
      expect_fields(c, "legal record");
      expect_bad(1'b0, "legal record");
      legal_checked++;
    end

    // 2. directed malformed records; the fields still decode
    c = rand_command();
    for (int kind = 0; kind < 4; kind++) begin
      if (kind != 1) begin
        apply(encode(c, 2'(kind), 8'd1));
        expect_bad(1'b1, $sformatf("kind %0d", kind));
        malformed_checked++;
      end
    end
    for (int v = 0; v < 256; v += 51) begin
      if (v != 1) begin
        apply(encode(c, 2'd1, 8'(v)));
        expect_bad(1'b1, $sformatf("version %0d", v));
        malformed_checked++;
      end
    end
    for (int f = 5; f < 8; f++) begin
      c.out_format = 3'(f);
      apply(encode(c, 2'd1, 8'd1));
      expect_fields(c, $sformatf("format %0d", f));
      expect_bad(1'b1, $sformatf("format %0d", f));
      malformed_checked++;
    end
    c.out_format = OUT_FP16;
    for (int fr = 32; fr < 64; fr += 31) begin
      c.out_frac = 6'(fr);
      apply(encode(c, 2'd1, 8'd1));
      expect_bad(1'b1, $sformatf("frac %0d", fr));
      malformed_checked++;
    end
    c.out_frac = 6'd31;
    apply(encode(c, 2'd1, 8'd1));
    expect_bad(1'b0, "frac 31");
    c.trans_a = 1'b1;
    apply(encode(c, 2'd1, 8'd1));
    expect_fields(c, "transpose A");
    expect_bad(1'b1, "transpose A");
    c.trans_a = 1'b0;
    c.trans_b = 1'b1;
    apply(encode(c, 2'd1, 8'd1));
    expect_fields(c, "transpose B");
    expect_bad(1'b1, "transpose B");
    c.trans_b = 1'b0;
    malformed_checked += 2;
    for (int b = 0; b < RECORD_W; b++) begin
      if (reserved_mask[b]) begin
        r    = encode(c, 2'd1, 8'd1);
        r[b] = 1'b1;
        apply(r);
        expect_fields(c, $sformatf("reserved bit %0d", b));
        expect_bad(1'b1, $sformatf("reserved bit %0d", b));
        reserved_bits++;
        malformed_checked++;
      end
    end

    // 3. random bit flips of legal records
    for (int n = 0; n < Records; n++) begin
      r = encode(rand_command(), 2'd1, 8'd1);
      r[rand32()%RECORD_W] ^= 1'b1;
      if (n % 2 == 0) begin
        r[rand32()%RECORD_W] ^= 1'b1;
      end
      want = ref_malformed(r);
      apply(r);
      expect_bad(want, "bit flip");
      flips_checked++;
      flips_malformed += int'(want);
    end

    // 4. ready/valid pass through
    for (int n = 0; n < 4; n++) begin
      rec_valid = n[0];
      cmd_ready = n[1];
      #1;
      if (cmd_valid !== rec_valid || rec_ready !== cmd_ready) begin
        errors++;
        $display("bpu_sa_command_decoder_tb: valid %b -> %b, ready %b -> %b", rec_valid, cmd_valid,
                 cmd_ready, rec_ready);
      end
    end

    // Reserved: word 0 bits 7:2 and 31:16 (22), word 9 bit 31 (1), word 11 bits 31:7
    // (25) and words 12 to 15 (128): 176 bits.
    if (errors != 0 || legal_checked != Records || reserved_bits != 176
        || flips_malformed == 0 || flips_malformed == flips_checked) begin
      status = "FAIL";
    end else begin
      status = "PASS";
    end
    $write("RESULT bpu_sa_command_decoder_tb seed=%0d legal=%0d malformed=%0d", seed,
           legal_checked, malformed_checked);
    $display(" reserved_bits=%0d flips=%0d flips_malformed=%0d errors=%0d status=%s",
             reserved_bits, flips_checked, flips_malformed, errors, status);
    if (status != "PASS") begin
      $fatal(1, "bpu_sa_command_decoder_tb: FAIL (%0d errors)", errors);
    end
    $finish;
  end

endmodule
