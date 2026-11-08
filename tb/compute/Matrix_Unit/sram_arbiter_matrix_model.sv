// Testbench model of the sram_arbiter matrix port with the SRAM behind it, for
// bpu_sa_sram_wrapper_tb. Behavioural, not synthesizable. It follows the port
// contract in docs/memory/sram_arbiter_io_scheme.md (§4): ready/valid requests,
// one-cycle response pulses with no backpressure, fixed latency (so responses come
// back in request order), byte addresses and sizes.
//
// Behaviour
//   Request  req_ready_o is 1 on ReadyPct percent of cycles, chosen at random each
//            cycle and independent of req_valid_i (the other requesters winning).
//   Read     rsp_valid_o pulses in the Latency-th cycle after the edge that
//            accepted the read (Latency = 1: the very next cycle). Byte n of rsp_rdata_o is mem[addr + n] for n < size_bytes and
//            random garbage above, so a client that uses bytes it did not ask for
//            fails.
//   Write    address, size and data are captured on acceptance. Bytes become
//            visible only at completion, at least WriteLatency edges later.
//            WriteLatency counts edges from acceptance to memory commit and
//            registered pulse assertion; the DUT samples that pulse one edge
//            later. It is independent of the read pipeline's Latency setting.
//            WriteAcks = 0 uses wr_done_o; WriteAcks = 1 uses rsp_valid_o.
//            hold_write_completion_i delays visibility and completion together.
//   Reset    drops queued writes and every response still in flight. Committed
//            bytes and the cumulative counters retain their values.
//
// Checks (each one prints a message and adds to errors_o)
//   - a request stalled at a rising edge is still offered, unchanged, at the next
//   - req_valid_i is 0 or 1 (never X or Z) out of reset
//   - the address is row aligned, 1 <= size_bytes <= DataW/8, and the access fits
//     in the memory
//   - a read lies inside one of the four read windows [rd_lo_i[w], rd_hi_i[w]) (A,
//     B and the two scale tables); a write lies inside [c_lo_i, c_hi_i) and
//     carries no X or Z bytes
//
// The testbench reads and writes the memory directly through mem (hierarchical
// references) and reads the counters through the *_o ports. in_flight_o counts the
// reads and writes accepted but not yet completed; output pulses are excluded.
//
// Parameters: AddrW, DataW, SizeW (the port), MemBytes, Latency (>= 1), ReadyPct
// (1 .. 100), WriteAcks. Plusarg +seed=<n> seeds the ready and garbage generator.
module sram_arbiter_matrix_model #(
  parameter int AddrW        = 32,
  parameter int DataW        = 4096,
  parameter int SizeW        = 10,
  parameter int MemBytes     = 65536,
  parameter int Latency      = 4,
  parameter int WriteLatency = Latency + 8,
  parameter int ReadyPct     = 70,
  parameter bit WriteAcks    = 1'b0
) (
  input logic clk_i,
  input logic rst_ni,
  input logic hold_write_completion_i,

  // Matrix port, as the arbiter sees it
  input  logic             req_valid_i,
  output logic             req_ready_o,
  input  logic             req_is_write_i,
  input  logic [SizeW-1:0] req_size_bytes_i,
  input  logic [AddrW-1:0] req_addr_i,
  input  logic [DataW-1:0] req_wdata_i,
  output logic             rsp_valid_o,
  output logic [DataW-1:0] rsp_rdata_o,
  output logic             wr_done_o,

  // Allowed address ranges, half-open: reads in one of four windows, writes in C
  input logic [3:0][AddrW-1:0] rd_lo_i,
  input logic [3:0][AddrW-1:0] rd_hi_i,
  input logic [AddrW-1:0] c_lo_i,
  input logic [AddrW-1:0] c_hi_i,

  // Counters since time 0
  output int reads_o,
  output int writes_o,
  output int read_bytes_o,
  output int write_bytes_o,
  output int errors_o,
  output int stalls_o,
  output int in_flight_o,
  output int write_in_flight_o,
  output int completed_writes_o
);

  localparam int ROW_BYTES = DataW / 8;

  logic [      7:0] mem       [MemBytes];

  // Responses in flight: a request accepted at an edge enters stage 0, moves one
  // stage per edge, and is driven out from stage Latency - 1.
  bit               pipe_valid[ Latency];
  logic [DataW-1:0] pipe_data [ Latency];

  typedef struct packed {
    logic [AddrW-1:0] addr;
    logic [SizeW-1:0] size_bytes;
    logic [DataW-1:0] data;
    longint unsigned  due_cycle;
  } pending_write_t;
  pending_write_t              pending_writes[$];
  longint unsigned             model_cycle;

  int unsigned                 rng_state;
  int                          seed;
  bit                          prev_stall;
  logic            [      0:0] prev_is_write;
  logic            [SizeW-1:0] prev_size;
  logic            [AddrW-1:0] prev_addr;
  logic            [DataW-1:0] prev_wdata;

  function automatic int unsigned rand32();
    rng_state = rng_state ^ (rng_state << 13);
    rng_state = rng_state ^ (rng_state >> 17);
    rng_state = rng_state ^ (rng_state << 5);
    return rng_state;
  endfunction

  function automatic bit in_range(input longint lo, input longint hi, input longint first,
                                  input longint last_plus_one);
    return first >= lo && last_plus_one <= hi;
  endfunction

  task automatic fail(input string msg);
    errors_o++;
    if (errors_o <= 10) begin
      $display("sram_arbiter_matrix_model: %s (t=%0t)", msg, $time);
    end
  endtask

  initial begin
    if (Latency < 1 || WriteLatency < 1 || ReadyPct < 1 || ReadyPct > 100) begin
      $fatal(1, "sram_arbiter_matrix_model: latencies must be >= 1 and ReadyPct 1 .. 100");
    end
    if (!$value$plusargs("seed=%d", seed)) begin
      seed = 1;
    end
    rng_state = seed ^ 32'h5bd1_e995;
    if (rng_state == 0) begin
      rng_state = 1;
    end
    reads_o            = 0;
    writes_o           = 0;
    read_bytes_o       = 0;
    write_bytes_o      = 0;
    errors_o           = 0;
    stalls_o           = 0;
    in_flight_o        = 0;
    write_in_flight_o  = 0;
    completed_writes_o = 0;
    model_cycle        = 0;
    req_ready_o        = 1'b0;
    rsp_valid_o        = 1'b0;
    wr_done_o          = 1'b0;
    rsp_rdata_o        = '0;
    prev_stall         = 1'b0;
    for (int s = 0; s < Latency; s++) begin
      pipe_valid[s] = 1'b0;
    end
  end

  always @(posedge clk_i or negedge rst_ni) begin : model
    logic           [DataW-1:0] data;
    longint                     addr;
    longint                     size;
    bit                         accept;
    bit                         in_window;
    bit                         write_complete;
    pending_write_t             write_item;

    if (!rst_ni) begin
      for (int s = 0; s < Latency; s++) begin
        pipe_valid[s] = 1'b0;
      end
      prev_stall  = 1'b0;
      in_flight_o = 0;
      pending_writes.delete();
      write_in_flight_o = 0;
      model_cycle = 0;
      req_ready_o <= 1'b0;
      rsp_valid_o <= 1'b0;
      wr_done_o   <= 1'b0;
    end else begin
      model_cycle++;
      write_complete = 1'b0;
      // Retire before accepting: a write cannot complete on its acceptance edge.
      if (pending_writes.size() != 0 && !hold_write_completion_i) begin
        if (pending_writes[0].due_cycle <= model_cycle) begin
          write_item = pending_writes.pop_front();
          for (int n = 0; n < int'(write_item.size_bytes); n++) begin
            mem[int'(write_item.addr)+n] = write_item.data[8*n+:8];
          end
          write_complete = 1'b1;
          completed_writes_o++;
        end
      end
      // Protocol checks on what the client offered during the cycle that just ended.
      if (req_valid_i !== 1'b0 && req_valid_i !== 1'b1) begin
        fail("req_valid_i is X or Z");
      end
      if (prev_stall) begin
        if (req_valid_i !== 1'b1 || req_is_write_i !== prev_is_write[0]
            || req_size_bytes_i !== prev_size || req_addr_i !== prev_addr
            || req_wdata_i !== prev_wdata) begin
          fail("a stalled request was withdrawn or changed");
        end
      end
      accept     = (req_valid_i === 1'b1) && req_ready_o;
      prev_stall = (req_valid_i === 1'b1) && !req_ready_o;
      if (prev_stall) begin
        stalls_o++;
      end
      prev_is_write = req_is_write_i;
      prev_size     = req_size_bytes_i;
      prev_addr     = req_addr_i;
      prev_wdata    = req_wdata_i;

      // Advance the response pipeline; stage 0 takes this edge's request, if any.
      for (int s = Latency - 1; s > 0; s--) begin
        pipe_valid[s] = pipe_valid[s-1];
        pipe_data[s]  = pipe_data[s-1];
      end
      pipe_valid[0] = 1'b0;

      if (accept) begin
        addr = longint'(req_addr_i);
        size = longint'(req_size_bytes_i);
        if (addr % ROW_BYTES != 0 || size < 1 || size > ROW_BYTES || addr + size > MemBytes) begin
          fail($sformatf("bad request: addr %0d size %0d", addr, size));
        end else if (req_is_write_i === 1'b1) begin
          if (!in_range(c_lo_i, c_hi_i, addr, addr + size)) begin
            fail($sformatf(
                 "write [%0d, %0d) outside C [%0d, %0d)", addr, addr + size, c_lo_i, c_hi_i));
          end
          for (int n = 0; n < size; n++) begin
            if ($isunknown(req_wdata_i[8*n+:8])) begin
              fail($sformatf("write byte %0d is X or Z", n));
            end
          end
          writes_o++;
          write_bytes_o += int'(size);
          write_item.addr = req_addr_i;
          write_item.size_bytes = req_size_bytes_i;
          write_item.data = req_wdata_i;
          write_item.due_cycle = model_cycle + longint'(WriteLatency);
          pending_writes.push_back(write_item);
        end else begin
          in_window = 1'b0;
          for (int w = 0; w < 4; w++) begin
            if (in_range(rd_lo_i[w], rd_hi_i[w], addr, addr + size)) begin
              in_window = 1'b1;
            end
          end
          if (!in_window) begin
            fail($sformatf("read [%0d, %0d) outside every read window", addr, addr + size));
          end
          for (int w = 0; w < DataW / 32; w++) begin
            data[32*w+:32] = rand32();
          end
          for (int n = 0; n < size; n++) begin
            data[8*n+:8] = mem[addr+n];
          end
          reads_o++;
          read_bytes_o += int'(size);
          pipe_valid[0] = 1'b1;
          pipe_data[0]  = data;
        end
      end
      // A request accepted at this edge comes out Latency - 1 edges later.
      if (WriteAcks && write_complete && pipe_valid[Latency-1]) begin
        fail("read and shared write completion collided");
      end
      rsp_valid_o <= pipe_valid[Latency-1] || (WriteAcks && write_complete);
      rsp_rdata_o <= pipe_data[Latency-1];
      wr_done_o   <= !WriteAcks && write_complete;
      write_in_flight_o = pending_writes.size();
      in_flight_o = write_in_flight_o;
      for (int s = 0; s < Latency - 1; s++) begin
        in_flight_o += int'(pipe_valid[s]);
      end
      req_ready_o <= (int'(rand32() % 100) < ReadyPct);
    end
  end

endmodule
