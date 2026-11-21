// Testbench model of the sram_arbiter as its specification defines it
// (docs/memory/sram_arbiter_spec.md, rtl #32 at 4ee902b), with the SRAM behind it, for
// bpu_matrix_unit_system_tb. Behavioural, not synthesizable. It stands in for the
// arbiter RTL until that RTL implements the specification's Matrix channel (rtl #35 at
// ea35ff9 has no transpose, element-width or fault ports yet).
//
// Behaviour
//   Channels   Memory (mm_*), Matrix (matrix_*) and Vector (vec_*), one request
//              channel each, ordinary row accesses only. At most one request is
//              accepted per cycle, by fixed priority Memory > Matrix > Vector. On
//              StallPct percent of cycles, chosen at random, the SRAM accepts nothing
//              (a busy bank), so a lower-priority channel can wait behind both.
//   Ready      *_req_ready_o depends combinationally on this cycle's requests: every
//              valid (the priority choice) and the chosen request's fields (the fault
//              check). Every client here drives its request from registers, so the
//              path makes no loop.
//   Read     accepted on rising edge n, completes on edge n + 1: *_rsp_valid_o is
//              high for the one cycle in between and *_rsp_rdata_o is the whole row,
//              including any write that committed on edge n.
//   Write      accepted on edge n, committed and visible by edge n + 1. Memory writes
//              all ROW_BYTES bytes; Matrix and Vector write bytes 0 .. size_bytes - 1 of the
//              row. There is no write acknowledgment.
//   Fault      the selected request faults, is withheld and raises fault_o on the
//              next edge when its address is not row aligned or its row is outside
//              the memory, a Matrix or Vector size is outside 1 .. ROW_BYTES, or a Matrix
//              request asks for the transpose view (a valid request in the
//              specification, but no client tested here may issue one). fault_o is
//              sticky; nothing is accepted after it until reset.
//   Reset      cancels a write that has not reached its commit edge and drops the
//              response in flight. Memory contents and the counters are kept.
//
// Checks (each prints a message and adds to errors_o): a request that was offered and
// not accepted at a rising edge is still offered, unchanged, at the next; request
// valids are never X or Z out of reset.
//
// The testbench reads and writes the memory through mem (hierarchical references).
// Plusarg +seed=<n> seeds the stall generator.
module sram_arbiter_spec_model #(
  parameter int AddrW    = 32,
  parameter int DataW    = 4096,
  parameter int SizeW    = 10,
  parameter int MemBytes = 65536,
  parameter int StallPct = 0
) (
  input logic clk_i,
  input logic rst_ni,

  input  logic             mm_req_valid_i,
  output logic             mm_req_ready_o,
  input  logic             mm_req_is_write_i,
  input  logic [AddrW-1:0] mm_req_addr_i,
  input  logic [DataW-1:0] mm_req_wdata_i,
  output logic             mm_rsp_valid_o,
  output logic [DataW-1:0] mm_rsp_rdata_o,

  input  logic             matrix_req_valid_i,
  output logic             matrix_req_ready_o,
  input  logic             matrix_req_is_write_i,
  input  logic [SizeW-1:0] matrix_req_size_bytes_i,
  input  logic [AddrW-1:0] matrix_req_addr_i,
  input  logic [DataW-1:0] matrix_req_wdata_i,
  input  logic             matrix_req_transpose_i,
  input  logic [      1:0] matrix_req_element_width_i,
  output logic             matrix_rsp_valid_o,
  output logic [DataW-1:0] matrix_rsp_rdata_o,

  input  logic             vec_req_valid_i,
  output logic             vec_req_ready_o,
  input  logic             vec_req_is_write_i,
  input  logic [SizeW-1:0] vec_req_size_bytes_i,
  input  logic [AddrW-1:0] vec_req_addr_i,
  input  logic [DataW-1:0] vec_req_wdata_i,
  output logic             vec_rsp_valid_o,
  output logic [DataW-1:0] vec_rsp_rdata_o,

  output logic fault_o,

  // Counters since time 0, indexed Memory 0, Matrix 1, Vector 2
  output int accepted_o[3],
  output int waited_o  [3],  // cycles a channel's request was offered and not accepted
  output int errors_o
);

  localparam int ROW_BYTES = DataW / 8;
  localparam int MEMORY = 0;
  localparam int MATRIX = 1;
  localparam int VECTOR = 2;

  logic [7:0] mem[MemBytes];

  logic [2:0] valid;
  logic [2:0] is_write;
  logic [2:0][AddrW-1:0] addr;
  logic [2:0][DataW-1:0] wdata;
  logic [2:0][SizeW:0] size;  // bytes, one bit wider so ROW_BYTES fits
  logic [2:0] legal;
  logic [2:0] ready;
  int sel;  // the channel the SRAM would serve this cycle, -1 for none
  logic busy_q;  // this cycle's random bank-busy
  logic fault_q;
  int unsigned rng;
  int seed;

  // Last cycle's offer, for the stability check
  logic [2:0] held_q;
  logic [2:0] held_write_q;
  logic [2:0][AddrW-1:0] held_addr_q;
  logic [2:0][DataW-1:0] held_wdata_q;
  logic [2:0][SizeW:0] held_size_q;

  // The write accepted on the last edge, committed on this one
  logic pend_q;
  logic [AddrW-1:0] pend_addr_q;
  logic [DataW-1:0] pend_data_q;
  int pend_size_q;

  function automatic int unsigned rand32();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  initial begin
    if (!$value$plusargs("seed=%d", seed)) begin
      seed = 1;
    end
    rng = 32'h1234_5679 ^ (seed * 32'd2654435761);
    errors_o = 0;
    for (int c = 0; c < 3; c++) begin
      accepted_o[c] = 0;
      waited_o[c]   = 0;
    end
  end

  assign valid = {vec_req_valid_i === 1'b1, matrix_req_valid_i === 1'b1, mm_req_valid_i === 1'b1};
  assign is_write = {vec_req_is_write_i, matrix_req_is_write_i, mm_req_is_write_i};
  assign addr = {vec_req_addr_i, matrix_req_addr_i, mm_req_addr_i};
  assign wdata = {vec_req_wdata_i, matrix_req_wdata_i, mm_req_wdata_i};
  assign size = {
    (SizeW + 1)'(vec_req_size_bytes_i),
    (SizeW + 1)'(matrix_req_size_bytes_i),
    (SizeW + 1)'(ROW_BYTES)
  };

  always_comb begin
    for (int c = 0; c < 3; c++) begin
      legal[c] = (addr[c] % ROW_BYTES == 0) && (64'(addr[c]) + ROW_BYTES <= 64'(MemBytes))
                 && (size[c] >= 1) && (size[c] <= ROW_BYTES)
                 && !(c == MATRIX && matrix_req_transpose_i === 1'b1);
    end
    sel = -1;
    if (rst_ni && !busy_q && !fault_q) begin
      for (int c = 2; c >= 0; c--) begin
        if (valid[c]) begin
          sel = c;
        end
      end
    end
    ready = '0;
    if (sel >= 0 && legal[sel]) begin
      ready[sel] = 1'b1;
    end
  end

  assign mm_req_ready_o = ready[MEMORY];
  assign matrix_req_ready_o = ready[MATRIX];
  assign vec_req_ready_o = ready[VECTOR];
  assign fault_o = fault_q;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pend_q             <= 1'b0;
      fault_q            <= 1'b0;
      busy_q             <= 1'b0;
      held_q             <= '0;
      mm_rsp_valid_o     <= 1'b0;
      matrix_rsp_valid_o <= 1'b0;
      vec_rsp_valid_o    <= 1'b0;
    end else begin
      // Checks on this edge's offers
      if ($isunknown({mm_req_valid_i, matrix_req_valid_i, vec_req_valid_i})) begin
        errors_o++;
        $display("sram_arbiter_spec_model: request valid unknown");
      end
      for (int c = 0; c < 3; c++) begin
        if (held_q[c] && (!valid[c] || is_write[c] !== held_write_q[c] || addr[c] !== held_addr_q[c]
                          || size[c] !== held_size_q[c]
                          || (is_write[c] && wdata[c] !== held_wdata_q[c]))) begin
          errors_o++;
          $display("sram_arbiter_spec_model: channel %0d changed a stalled request", c);
        end
        if (valid[c] && !ready[c]) begin
          waited_o[c]++;
        end
      end
      // Commit last edge's write before this edge's read samples the row.
      if (pend_q) begin
        for (int b = 0; b < pend_size_q; b++) begin
          mem[pend_addr_q+b] <= pend_data_q[8*b+:8];
        end
      end
      pend_q             <= 1'b0;
      mm_rsp_valid_o     <= 1'b0;
      matrix_rsp_valid_o <= 1'b0;
      vec_rsp_valid_o    <= 1'b0;
      if (sel >= 0 && !legal[sel]) begin
        fault_q <= 1'b1;
        $display("sram_arbiter_spec_model: channel %0d request faulted (address %0d, size %0d)",
                 sel, addr[sel], size[sel]);
      end
      if (sel >= 0 && legal[sel]) begin
        accepted_o[sel]++;
        if (is_write[sel]) begin
          pend_q      <= 1'b1;
          pend_addr_q <= addr[sel];
          pend_data_q <= wdata[sel];
          pend_size_q <= int'(size[sel]);
        end else begin
          logic [DataW-1:0] row;
          for (int b = 0; b < ROW_BYTES; b++) begin
            // The write committing on this edge is visible to this read.
            if (pend_q && addr[sel] + b >= pend_addr_q && addr[sel] + b < pend_addr_q + pend_size_q)
            begin
              row[8*b+:8] = pend_data_q[8*(addr[sel]+b-pend_addr_q)+:8];
            end else begin
              row[8*b+:8] = mem[addr[sel]+b];
            end
          end
          case (sel)
            MEMORY: begin
              mm_rsp_valid_o <= 1'b1;
              mm_rsp_rdata_o <= row;
            end
            MATRIX: begin
              matrix_rsp_valid_o <= 1'b1;
              matrix_rsp_rdata_o <= row;
            end
            default: begin
              vec_rsp_valid_o <= 1'b1;
              vec_rsp_rdata_o <= row;
            end
          endcase
        end
      end
      for (int c = 0; c < 3; c++) begin
        held_q[c]       <= valid[c] && !ready[c] && !(sel == c && !legal[c]);
        held_write_q[c] <= is_write[c];
        held_addr_q[c]  <= addr[c];
        held_wdata_q[c] <= wdata[c];
        held_size_q[c]  <= size[c];
      end
      busy_q <= (rand32() % 100) < StallPct;
    end
  end

endmodule
