// Provisional integration boundary. Not the accepted software ABI.
package command_pkg;
  parameter int unsigned NUM_ROUTES = 5;
  parameter logic [15:0] COMMAND_ABI_VERSION = 16'd1;
  parameter logic [15:0] OPCODE_MATRIX = 16'd1;
  parameter logic [15:0] OPCODE_VECTOR_TEST = 16'h8002;
  parameter logic [15:0] OPCODE_STATE_TEST = 16'h8003;
  parameter logic [15:0] OPCODE_MEMORY_TEST = 16'h8004;

  typedef enum logic [2:0] {
    RouteMatrix,
    RouteVector,
    RouteState,
    RouteMemory,
    RouteInvalid
  } route_e;
  typedef enum logic [7:0] {
    StatusUnimplemented = 8'h80,
    StatusBadCommand = 8'h81
  } completion_status_e;
  typedef struct packed {
    logic [31:0] sequence_id;
    logic [31:0] context_id;
    logic [15:0] opcode;
    logic [15:0] abi_version;
    logic [63:0] a_addr;
    logic [63:0] b_addr;
    logic [63:0] c_addr;
    logic [63:0] state_addr;
    logic [31:0] m;
    logic [31:0] n;
    logic [31:0] k;
    logic [31:0] a_stride;
    logic [31:0] b_stride;
    logic [31:0] c_stride;
    logic [31:0] format_id;
  } command_t;
  typedef struct packed {
    logic [31:0] sequence_id;
    completion_status_e status;
  } completion_t;
  // Only opcode 1 comes from the slide baseline. Others are test routing values.
  function automatic route_e decode_route(input logic [15:0] opcode);
    case (opcode)
      OPCODE_MATRIX: return RouteMatrix;
      OPCODE_VECTOR_TEST: return RouteVector;
      OPCODE_STATE_TEST: return RouteState;
      OPCODE_MEMORY_TEST: return RouteMemory;
      default: return RouteInvalid;
    endcase
  endfunction
endpackage
