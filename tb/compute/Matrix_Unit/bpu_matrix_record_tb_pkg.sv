// The Matrix version-1 command record for the testbenches, from the specification's
// table (docs/compute/bpu_matrix_unit_spec.md, section 7.2). It is written from the
// table, not from bpu_sa_command_decoder, so a decoder that misplaces a field fails.
package bpu_matrix_record_tb_pkg;
  import bpu_sa_golden_vectors_pkg::*;

  localparam int RECORD_BITS = 512;
  localparam logic [1:0] KIND_MATRIX = 2'd1;

  // Field positions in the record (word w is bits 32w+31 : 32w)
  localparam int KIND_LSB = 0;  // 2 bits, in every kind of record
  localparam int VERSION_LSB = 8;  // 8 bits
  localparam int MEMORY_WAIT_LSB = 32;  // 32 bits each, to B_SCALE_ADDRESS
  localparam int VECTOR_WAIT_LSB = 64;
  localparam int A_ADDRESS_LSB = 96;
  localparam int B_ADDRESS_LSB = 128;
  localparam int C_ADDRESS_LSB = 160;
  localparam int A_SCALE_ADDRESS_LSB = 192;
  localparam int B_SCALE_ADDRESS_LSB = 224;
  localparam int M_LSB = 256;  // 16 bits each, to K
  localparam int N_LSB = 272;
  localparam int K_LSB = 288;
  localparam int TRANSPOSE_A_BIT = 304;
  localparam int CLEAR_ACC_BIT = 306;
  localparam int WRITE_OUTPUT_BIT = 307;
  localparam int INT4_BIT = 308;
  localparam int SCALED_BIT = 309;

  // Golden command n as a record. Output format 0 (legacy) with no fractional bits and
  // no requantization, so words 10 and 11 are zero.
  function automatic logic [RECORD_BITS-1:0] matrix_record(input int n, input logic [7:0] version,
                                                           input logic [31:0] memory_wait,
                                                           input logic [31:0] vector_wait);
    logic [RECORD_BITS-1:0] r;
    r                          = '0;
    r[KIND_LSB+:2]             = KIND_MATRIX;
    r[VERSION_LSB+:8]          = version;
    r[MEMORY_WAIT_LSB+:32]     = memory_wait;
    r[VECTOR_WAIT_LSB+:32]     = vector_wait;
    r[A_ADDRESS_LSB+:32]       = GV_CMD[n][5];
    r[B_ADDRESS_LSB+:32]       = GV_CMD[n][6];
    r[C_ADDRESS_LSB+:32]       = GV_CMD[n][9];
    r[A_SCALE_ADDRESS_LSB+:32] = GV_CMD[n][7];
    r[B_SCALE_ADDRESS_LSB+:32] = GV_CMD[n][8];
    r[M_LSB+:16]               = 16'(GV_ROWS);
    r[N_LSB+:16]               = 16'(GV_COLS);
    r[K_LSB+:16]               = 16'(GV_CMD[n][0]);
    r[CLEAR_ACC_BIT]           = GV_CMD[n][3][0];
    r[WRITE_OUTPUT_BIT]        = GV_CMD[n][4][0];
    r[INT4_BIT]                = GV_CMD[n][1][0];
    r[SCALED_BIT]              = GV_CMD[n][2][0];
    return r;
  endfunction

endpackage
