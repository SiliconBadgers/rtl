// Decodes the 512-bit version-1 Matrix record (docs/compute/bpu_matrix_unit_spec.md,
// section 7.2) into bpu_sa_pkg::matrix_command_t, with a malformed-record flag for the
// wrapper's cmd_decode_error_i. Purely combinational: ready and valid pass straight
// through, and the fields follow rec_i in the same cycle.
//
// Malformed: kind or version not 1; a reserved bit set (word 0 bits 7:2 and 31:16, word 9
// bit 31, word 11 bits 31:7, words 12 to 15); an output format above 4; fractional bits
// above 31; either transpose bit set. Checks against the build (M, N, K, alignment,
// supported modes) are the wrapper's. The wait targets are passed on, and bpu_matrix_unit
// ignores them.
module bpu_sa_command_decoder
  import bpu_sa_pkg::*;
(
  input  logic                rec_valid_i,
  output logic                rec_ready_o,
  input  logic [RECORD_W-1:0] rec_i,

  output logic            cmd_valid_o,
  input  logic            cmd_ready_i,
  output matrix_command_t cmd_o,
  output logic            cmd_decode_error_o
);

  logic [15:0][31:0] w;  // the record's words
  logic reserved_set;

  assign w = rec_i;
  assign rec_ready_o = cmd_ready_i;
  assign cmd_valid_o = rec_valid_i;

  assign cmd_o.mem_wait = w[1];
  assign cmd_o.vec_wait = w[2];
  assign cmd_o.a_addr = w[3];
  assign cmd_o.b_addr = w[4];
  assign cmd_o.c_addr = w[5];
  assign cmd_o.sa_addr = w[6];
  assign cmd_o.sb_addr = w[7];
  assign cmd_o.m = w[8][15:0];
  assign cmd_o.n = w[8][31:16];
  assign cmd_o.k = w[9][15:0];
  assign cmd_o.trans_a = w[9][16];
  assign cmd_o.trans_b = w[9][17];
  assign cmd_o.clear_acc = w[9][18];
  assign cmd_o.write_output = w[9][19];
  assign cmd_o.int4 = w[9][20];
  assign cmd_o.scaled = w[9][21];
  assign cmd_o.out_format = w[9][24:22];
  assign cmd_o.out_frac = w[9][30:25];
  assign cmd_o.requant_mul = w[10];
  assign cmd_o.requant_shift = w[11][6:0];

  assign reserved_set = (w[0][7:2] != '0) || (w[0][31:16] != '0) || w[9][31]
      || (w[11][31:7] != '0) || (w[12] != '0) || (w[13] != '0) || (w[14] != '0)
      || (w[15] != '0);

  assign cmd_decode_error_o = (w[0][1:0] != RECORD_KIND_MATRIX)
      || (w[0][15:8] != RECORD_VERSION) || reserved_set
      || (w[9][24:22] > OUT_INT8) || w[9][30] || w[9][16] || w[9][17];

endmodule
