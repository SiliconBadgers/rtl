// Latency probe for the AWS F2 two-stack AMD HBM model.
//
// The functional test (f2_hbm_tb) checks data and protocol. This bench measures
// timing instead: it issues 16-beat reads and writes in controlled patterns and
// logs per-burst cycle stamps to latency.csv in the working directory. Ready
// signals on R and B stay high so the measurement reflects the memory, not the
// testbench. Cycle stamps count AXI clock edges after reset deassertion.
//
// Phases (tag column meaning in brackets):
//   1 idle      one read at a time from every port to its own pseudo-channel, PC 0
//               and PC 16, three repeats per address [dst_pc * 256 + repeat]
//   2 stride    port 0 alternates two addresses 2^k bytes apart [k; 0 = same address]
//   3 depth     port 0 sequential reads with N outstanding [N]
//   4 random    port 0 random reads within 64 MiB, 16 outstanding [0]
//   5 all_ports all 32 ports stream sequential reads to their own channel [0]
//   6 mixed     port 0 alternating reads and writes [0], then writes only [1]
//
// Every enabled phase must log its exact expected record count or the run fails
// with HBM_LATENCY_MISSING. +DROP_PHASE=<n> withholds a phase's traffic to
// exercise that failure. +SKIP_RESET=1 exercises the reset prerequisite.
module f2_hbm_latency_tb;
  timeunit 1ns; timeprecision 1ps;

  localparam int unsigned NUM_PORTS = 32;
  localparam int unsigned NUM_IDS = 64;
  localparam int unsigned BURST_BEATS = 16;
  localparam int unsigned BURST_BYTES = 512;
  localparam int unsigned NUM_PHASES = 6;
  localparam int unsigned ALL_PHASES = 32'h3f;
  localparam int unsigned DEPTHS[7] = '{1, 2, 4, 8, 16, 32, 64};
  localparam int unsigned DEPTH_BURSTS = 128;
  localparam int unsigned STRIDE_READS = 8;
  localparam int unsigned MIN_STRIDE_BIT = 5;
  localparam int unsigned MAX_STRIDE_BIT = 28;
  localparam int unsigned IDLE_REPEATS = 3;
  localparam int unsigned IDLE_GAP_CYCLES = 32;
  localparam int unsigned RANDOM_BURSTS = 256;
  localparam int unsigned RANDOM_SPAN_BURSTS = (64 * 1024 * 1024) / BURST_BYTES;
  localparam int unsigned MIXED_BURSTS = 256;
  localparam int unsigned WRITE_ONLY_BURSTS = 64;

  typedef enum int unsigned {
    PhaseNone = 0,
    PhaseIdle = 1,
    PhaseStride = 2,
    PhaseDepth = 3,
    PhaseRandom = 4,
    PhaseAllPorts = 5,
    PhaseMixed = 6
  } phase_e;

  typedef struct {
    logic [33:0] addr;
    bit is_write;
    int unsigned tag;
  } request_t;

  typedef struct {
    request_t request;
    phase_e phase;
    longint unsigned seq;
    longint unsigned valid_cycle;
    longint unsigned accept_cycle;
    longint unsigned data_cycle;
    int unsigned beats;
  } tracked_t;

  logic axi_clk = 1'b0;
  logic apb_clk = 1'b0;
  logic rst_n = 1'b0;
  wire [1:0] initialized;
  logic [NUM_PORTS-1:0][33:0] awaddr, araddr;
  logic [NUM_PORTS-1:0][5:0] awid, arid;
  logic [NUM_PORTS-1:0] awvalid, arvalid, wvalid, wlast;
  logic [NUM_PORTS-1:0][255:0] wdata;
  wire [NUM_PORTS-1:0] awready, arready, wready, bvalid, rvalid, rlast;
  wire [NUM_PORTS-1:0][255:0] rdata;
  wire [NUM_PORTS-1:0][5:0] bid, rid;
  wire [NUM_PORTS-1:0][1:0] bresp, rresp;

  longint unsigned cycle = 0;
  int unsigned reset_cycles = 0;
  int unsigned seed = 1;
  int unsigned rng_state = 1;
  int unsigned drop_phase = 0;
  int unsigned phase_mask = ALL_PHASES;
  int unsigned all_ports_cycles = 9000;
  bit skip_reset = 1'b0;
  int csv = 0;

  phase_e phase = PhaseNone;
  int unsigned min_gap_cycles = 0;
  int unsigned max_outstanding[NUM_PORTS];
  request_t pending[NUM_PORTS][$];
  tracked_t read_slot[NUM_PORTS][NUM_IDS];
  tracked_t write_slot[NUM_PORTS][NUM_IDS];
  bit read_busy[NUM_PORTS][NUM_IDS];
  bit write_busy[NUM_PORTS][NUM_IDS];
  int unsigned write_data_ids[NUM_PORTS][$];
  int unsigned write_beat[NUM_PORTS];
  int unsigned reads_in_flight[NUM_PORTS];
  int unsigned writes_in_flight[NUM_PORTS];
  int unsigned peak_reads_in_flight[NUM_PORTS];
  longint unsigned issue_seq[NUM_PORTS];
  longint unsigned last_done_cycle[NUM_PORTS];
  int unsigned logged[NUM_PHASES+1];

  always #1.111ns axi_clk = ~axi_clk;
  always #5ns apb_clk = ~apb_clk;

  // Same 32-port mapping as f2_hbm_tb. Every burst is 16 beats of 32 bytes.
  `define CONNECT_AXI(P, N) \
  .AXI_``P``_ACLK(axi_clk), \
  .AXI_``P``_ARESET_N(rst_n), \
  .AXI_``P``_AWADDR(awaddr[N]), \
  .AXI_``P``_AWBURST(2'b01), \
  .AXI_``P``_AWID(awid[N]), \
  .AXI_``P``_AWLEN(4'(BURST_BEATS - 1)), \
  .AXI_``P``_AWSIZE(3'd5), \
  .AXI_``P``_AWVALID(awvalid[N]), \
  .AXI_``P``_AWREADY(awready[N]), \
  .AXI_``P``_WDATA(wdata[N]), \
  .AXI_``P``_WDATA_PARITY(32'd0), \
  .AXI_``P``_WSTRB(32'hffff_ffff), \
  .AXI_``P``_WLAST(wlast[N]), \
  .AXI_``P``_WVALID(wvalid[N]), \
  .AXI_``P``_WREADY(wready[N]), \
  .AXI_``P``_BID(bid[N]), \
  .AXI_``P``_BRESP(bresp[N]), \
  .AXI_``P``_BVALID(bvalid[N]), \
  .AXI_``P``_BREADY(1'b1), \
  .AXI_``P``_ARADDR(araddr[N]), \
  .AXI_``P``_ARBURST(2'b01), \
  .AXI_``P``_ARID(arid[N]), \
  .AXI_``P``_ARLEN(4'(BURST_BEATS - 1)), \
  .AXI_``P``_ARSIZE(3'd5), \
  .AXI_``P``_ARVALID(arvalid[N]), \
  .AXI_``P``_ARREADY(arready[N]), \
  .AXI_``P``_RDATA(rdata[N]), \
  .AXI_``P``_RDATA_PARITY(), \
  .AXI_``P``_RID(rid[N]), \
  .AXI_``P``_RRESP(rresp[N]), \
  .AXI_``P``_RLAST(rlast[N]), \
  .AXI_``P``_RVALID(rvalid[N]), \
  .AXI_``P``_RREADY(1'b1)

  `define CONNECT_APB(P) \
  .APB_``P``_PCLK(apb_clk), \
  .APB_``P``_PRESET_N(rst_n), \
  .APB_``P``_PWDATA(32'd0), \
  .APB_``P``_PADDR(22'd0), \
  .APB_``P``_PENABLE(1'b0), \
  .APB_``P``_PSEL(1'b0), \
  .APB_``P``_PWRITE(1'b0), \
  .APB_``P``_PRDATA(), \
  .APB_``P``_PREADY(), \
  .APB_``P``_PSLVERR(), \
  .MON_APB_``P``_PRESET_N(rst_n), \
  .APB_``P``_PWDATA_MON(), \
  .APB_``P``_PADDR_MON(), \
  .APB_``P``_PENABLE_MON(), \
  .APB_``P``_PSEL_MON(), \
  .APB_``P``_PWRITE_MON(), \
  .APB_``P``_PRDATA_MON(), \
  .APB_``P``_PREADY_MON(), \
  .APB_``P``_PSLVERR_MON()

  cl_hbm u_hbm (
    // verilog_lint: waive module-port
    `CONNECT_AXI(00, 0),
    `CONNECT_AXI(01, 1),
    `CONNECT_AXI(02, 2),
    `CONNECT_AXI(03, 3),
    `CONNECT_AXI(04, 4),
    `CONNECT_AXI(05, 5),
    `CONNECT_AXI(06, 6),
    `CONNECT_AXI(07, 7),
    `CONNECT_AXI(08, 8),
    `CONNECT_AXI(09, 9),
    `CONNECT_AXI(10, 10),
    `CONNECT_AXI(11, 11),
    `CONNECT_AXI(12, 12),
    `CONNECT_AXI(13, 13),
    `CONNECT_AXI(14, 14),
    `CONNECT_AXI(15, 15),
    `CONNECT_AXI(16, 16),
    `CONNECT_AXI(17, 17),
    `CONNECT_AXI(18, 18),
    `CONNECT_AXI(19, 19),
    `CONNECT_AXI(20, 20),
    `CONNECT_AXI(21, 21),
    `CONNECT_AXI(22, 22),
    `CONNECT_AXI(23, 23),
    `CONNECT_AXI(24, 24),
    `CONNECT_AXI(25, 25),
    `CONNECT_AXI(26, 26),
    `CONNECT_AXI(27, 27),
    `CONNECT_AXI(28, 28),
    `CONNECT_AXI(29, 29),
    `CONNECT_AXI(30, 30),
    `CONNECT_AXI(31, 31),
    `CONNECT_APB(0),
    `CONNECT_APB(1),
    .HBM_REF_CLK_0(apb_clk),
    .HBM_REF_CLK_1(apb_clk),
    .apb_complete_0(initialized[0]),
    .apb_complete_1(initialized[1]),
    .DRAM_0_STAT_CATTRIP(),
    .DRAM_0_STAT_TEMP(),
    .DRAM_1_STAT_CATTRIP(),
    .DRAM_1_STAT_TEMP()
  );
  `undef CONNECT_AXI
  `undef CONNECT_APB

  for (genvar port_idx = 0; port_idx < NUM_PORTS; port_idx++) begin : gen_protocol_checks
    WriteDataStable_A :
    assert property (
      @(posedge axi_clk) disable iff (!rst_n)
      wvalid[port_idx] && !wready[port_idx] |=>
      wvalid[port_idx] && $stable(
      {wdata[port_idx], wlast[port_idx]}
    ))
    else $fatal(1, "HBM write data changed while stalled on port %0d", port_idx);
  end

  // Global address: bit 33 selects the stack, [32:29] the pseudo-channel.
  function automatic logic [33:0] pc_address(input int unsigned pc, input longint unsigned offset);
    return (34'(pc) << 29) | 34'(offset & 64'h1fff_ffe0);
  endfunction

  // Deterministic xorshift so every simulator draws the same random addresses.
  function automatic int unsigned next_random();
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
  endfunction

  function automatic int free_id(input bit busy[NUM_IDS]);
    for (int id = 0; id < NUM_IDS; id++) begin
      if (!busy[id]) begin
        return id;
      end
    end
    return -1;
  endfunction

  function automatic void log_record(input int unsigned port, input string direction,
                                     input tracked_t slot, input longint unsigned done_cycle);
    $fwrite(csv, "%s,%0d,%s,%0d,%0h,%0d,%0d,%0d,%0d,%0d\n", slot.phase.name(), port, direction,
            slot.seq, slot.request.addr, slot.request.tag, slot.valid_cycle, slot.accept_cycle,
            slot.data_cycle, done_cycle);
    logged[slot.phase]++;
  endfunction

  // One process observes every handshake and drives every master channel. Bookkeeping
  // uses blocking updates inside this process; DUT inputs change with nonblocking
  // assignments so the model samples the values present before this edge.
  always @(posedge axi_clk) begin : observe_and_drive
    if (!rst_n) begin
      reset_cycles++;
    end else begin
      cycle++;
      for (int unsigned port = 0; port < NUM_PORTS; port++) begin
        int id;
        bit ar_stalled;
        bit aw_stalled;
        request_t head;

        if (arvalid[port] && arready[port]) begin
          read_slot[port][arid[port]].accept_cycle = cycle;
        end
        if (awvalid[port] && awready[port]) begin
          write_slot[port][awid[port]].accept_cycle = cycle;
          write_data_ids[port].push_back(int'(awid[port]));
        end
        if (wvalid[port] && wready[port]) begin
          if (wlast[port]) begin
            write_slot[port][write_data_ids[port][0]].data_cycle = cycle;
            void'(write_data_ids[port].pop_front());
            write_beat[port] = 0;
          end else begin
            write_beat[port]++;
          end
        end
        if (rvalid[port]) begin
          id = int'(rid[port]);
          if (!read_busy[port][id]) begin
            $fatal(1, "HBM_UNEXPECTED_RESPONSE read port=%0d id=%0d", port, id);
          end
          if (rresp[port] !== 2'b00) begin
            $fatal(1, "HBM_RESPONSE_ERROR read port=%0d id=%0d resp=%b", port, id, rresp[port]);
          end
          if (read_slot[port][id].beats == 0) begin
            read_slot[port][id].data_cycle = cycle;
          end
          read_slot[port][id].beats++;
          if (rlast[port]) begin
            if (read_slot[port][id].beats != BURST_BEATS) begin
              $fatal(1, "HBM_BURST_LENGTH port=%0d id=%0d beats=%0d", port, id,
                     read_slot[port][id].beats);
            end
            log_record(port, "R", read_slot[port][id], cycle);
            read_busy[port][id] = 1'b0;
            reads_in_flight[port]--;
            last_done_cycle[port] = cycle;
          end
        end
        if (bvalid[port]) begin
          id = int'(bid[port]);
          if (!write_busy[port][id]) begin
            $fatal(1, "HBM_UNEXPECTED_RESPONSE write port=%0d id=%0d", port, id);
          end
          if (bresp[port] !== 2'b00) begin
            $fatal(1, "HBM_RESPONSE_ERROR write port=%0d id=%0d resp=%b", port, id, bresp[port]);
          end
          log_record(port, "W", write_slot[port][id], cycle);
          write_busy[port][id] = 1'b0;
          writes_in_flight[port]--;
          last_done_cycle[port] = cycle;
        end

        // Requests leave each port's queue in order: a stalled address channel
        // blocks everything behind it, as in the command format's Memory queue.
        ar_stalled = arvalid[port] && !arready[port];
        aw_stalled = awvalid[port] && !awready[port];
        arvalid[port] <= ar_stalled;
        awvalid[port] <= aw_stalled;
        if (!ar_stalled && !aw_stalled && pending[port].size() > 0 &&
            cycle >= last_done_cycle[port] + 64'(min_gap_cycles)) begin
          head = pending[port][0];
          if (!head.is_write && reads_in_flight[port] < max_outstanding[port]) begin
            id = free_id(read_busy[port]);
            if (id >= 0) begin
              void'(pending[port].pop_front());
              read_busy[port][id] = 1'b1;
              reads_in_flight[port]++;
              if (reads_in_flight[port] > peak_reads_in_flight[port]) begin
                peak_reads_in_flight[port] = reads_in_flight[port];
              end
              read_slot[port][id].request = head;
              read_slot[port][id].phase = phase;
              read_slot[port][id].seq = issue_seq[port]++;
              read_slot[port][id].valid_cycle = cycle;
              read_slot[port][id].accept_cycle = 0;
              read_slot[port][id].data_cycle = 0;
              read_slot[port][id].beats = 0;
              araddr[port] <= head.addr;
              arid[port] <= 6'(id);
              arvalid[port] <= 1'b1;
            end
          end else if (head.is_write && writes_in_flight[port] < max_outstanding[port]) begin
            id = free_id(write_busy[port]);
            if (id >= 0) begin
              void'(pending[port].pop_front());
              write_busy[port][id] = 1'b1;
              writes_in_flight[port]++;
              write_slot[port][id].request = head;
              write_slot[port][id].phase = phase;
              write_slot[port][id].seq = issue_seq[port]++;
              write_slot[port][id].valid_cycle = cycle;
              write_slot[port][id].accept_cycle = 0;
              write_slot[port][id].data_cycle = 0;
              write_slot[port][id].beats = 0;
              awaddr[port] <= head.addr;
              awid[port] <= 6'(id);
              awvalid[port] <= 1'b1;
            end
          end
        end

        // Write data follows accepted write addresses in order. The payload is a
        // function of the burst ID and beat, which only change on a handshake, so
        // WDATA and WLAST hold steady while WVALID waits for WREADY.
        wvalid[port] <= write_data_ids[port].size() > 0;
        wlast[port]  <= write_beat[port] == BURST_BEATS - 1;
        if (write_data_ids[port].size() > 0) begin
          wdata[port] <= {8{32'(write_data_ids[port][0]) << 16 | 32'(write_beat[port])}};
        end
      end
    end
  end

  function automatic bit traffic_idle();
    for (int unsigned port = 0; port < NUM_PORTS; port++) begin
      if (pending[port].size() > 0 || reads_in_flight[port] > 0 || writes_in_flight[port] > 0 ||
          write_data_ids[port].size() > 0 || arvalid[port] || awvalid[port]) begin
        return 1'b0;
      end
    end
    return 1'b1;
  endfunction

  task automatic drain();
    do begin
      @(negedge axi_clk);
    end while (!traffic_idle());
  endtask

  task automatic begin_phase(input phase_e next, input int unsigned outstanding,
                             input int unsigned gap_cycles);
    drain();
    phase = next;
    min_gap_cycles = gap_cycles;
    for (int unsigned port = 0; port < NUM_PORTS; port++) begin
      max_outstanding[port] = outstanding;
      peak_reads_in_flight[port] = 0;
    end
  endtask

  task automatic push(input int unsigned port, input logic [33:0] addr, input bit is_write,
                      input int unsigned tag);
    request_t request;
    if (drop_phase == phase) begin
      return;
    end
    request.addr = addr;
    request.is_write = is_write;
    request.tag = tag;
    pending[port].push_back(request);
  endtask

  task automatic end_phase(input phase_e checked, input int unsigned expected);
    drain();
    if (logged[checked] != expected) begin
      $fatal(1, "HBM_LATENCY_MISSING phase=%s logged=%0d expected=%0d", checked.name(),
             logged[checked], expected);
    end
    $display("HBM_LATENCY_PHASE %s records=%0d cycle=%0d", checked.name(), logged[checked], cycle);
  endtask

  function automatic bit enabled(input phase_e candidate);
    return phase_mask[candidate-1];
  endfunction

  task automatic run_idle();
    int unsigned destinations[3];
    begin_phase(PhaseIdle, 1, IDLE_GAP_CYCLES);
    for (int unsigned port = 0; port < NUM_PORTS; port++) begin
      destinations = '{port, 0, 16};
      foreach (destinations[dst]) begin
        for (int unsigned repeat_idx = 0; repeat_idx < IDLE_REPEATS; repeat_idx++) begin
          push(port, pc_address(destinations[dst], 64'(port) << 16), 1'b0,
               destinations[dst] * 256 + repeat_idx);
        end
      end
      // One source port at a time keeps the measurement free of switch contention.
      drain();
    end
    end_phase(PhaseIdle, NUM_PORTS * 3 * IDLE_REPEATS);
  endtask

  task automatic run_stride();
    int unsigned strides = 0;
    longint unsigned base = 64'h0010_0000;
    begin_phase(PhaseStride, 1, IDLE_GAP_CYCLES);
    for (int unsigned bit_idx = 0; bit_idx <= MAX_STRIDE_BIT; bit_idx++) begin
      if (bit_idx != 0 && bit_idx < MIN_STRIDE_BIT) begin
        continue;
      end
      strides++;
      for (int unsigned read_idx = 0; read_idx < STRIDE_READS; read_idx++) begin
        longint unsigned offset = base;
        if (bit_idx != 0 && read_idx % 2 == 1) begin
          offset = base + (64'd1 << bit_idx);
        end
        push(0, pc_address(0, offset), 1'b0, bit_idx);
      end
    end
    end_phase(PhaseStride, strides * STRIDE_READS);
  endtask

  task automatic run_depth();
    foreach (DEPTHS[depth_idx]) begin
      begin_phase(PhaseDepth, DEPTHS[depth_idx], 0);
      for (int unsigned burst = 0; burst < DEPTH_BURSTS; burst++) begin
        push(0, pc_address(0, (64'(depth_idx) << 22) + 64'(burst) * BURST_BYTES), 1'b0,
             DEPTHS[depth_idx]);
      end
      drain();
      $display("HBM_LATENCY_DEPTH requested=%0d peak_in_flight=%0d", DEPTHS[depth_idx],
               peak_reads_in_flight[0]);
    end
    end_phase(PhaseDepth, $size(DEPTHS) * DEPTH_BURSTS);
  endtask

  task automatic run_random();
    begin_phase(PhaseRandom, 16, 0);
    for (int unsigned burst = 0; burst < RANDOM_BURSTS; burst++) begin
      int unsigned slot = next_random() % RANDOM_SPAN_BURSTS;
      push(0, pc_address(0, 64'(slot) * BURST_BYTES), 1'b0, 0);
    end
    end_phase(PhaseRandom, RANDOM_BURSTS);
  endtask

  task automatic run_all_ports();
    int unsigned bursts_per_port = all_ports_cycles / BURST_BEATS;
    begin_phase(PhaseAllPorts, 32, 0);
    for (int unsigned burst = 0; burst < bursts_per_port; burst++) begin
      for (int unsigned port = 0; port < NUM_PORTS; port++) begin
        push(port, pc_address(port, 64'h0800_0000 + 64'(burst) * BURST_BYTES), 1'b0, 0);
      end
    end
    end_phase(PhaseAllPorts, NUM_PORTS * bursts_per_port);
  endtask

  task automatic run_mixed();
    begin_phase(PhaseMixed, 8, 0);
    for (int unsigned burst = 0; burst < MIXED_BURSTS; burst++) begin
      push(0, pc_address(0, 64'h1000_0000 + 64'(burst) * BURST_BYTES), burst % 2 == 1, 0);
    end
    // Finish the mixed segment before the write-only segment starts.
    drain();
    for (int unsigned burst = 0; burst < WRITE_ONLY_BURSTS; burst++) begin
      push(0, pc_address(0, 64'h1800_0000 + 64'(burst) * BURST_BYTES), 1'b1, 1);
    end
    end_phase(PhaseMixed, MIXED_BURSTS + WRITE_ONLY_BURSTS);
  endtask

  initial begin : watchdog
    int unsigned watchdog_us = 3000;
    void'($value$plusargs("WATCHDOG_US=%d", watchdog_us));
    #(1000ns * watchdog_us);
    $fatal(1, "HBM_TIMEOUT phase=%s cycle=%0d initialized=%b", phase.name(), cycle, initialized);
  end

  initial begin : stimulus
    awaddr = '0;
    araddr = '0;
    awid = '0;
    arid = '0;
    awvalid = '0;
    arvalid = '0;
    wvalid = '0;
    wlast = '0;
    wdata = '0;
    for (int unsigned port = 0; port < NUM_PORTS; port++) begin
      max_outstanding[port] = 1;
      write_beat[port] = 0;
      reads_in_flight[port] = 0;
      writes_in_flight[port] = 0;
      peak_reads_in_flight[port] = 0;
      issue_seq[port] = 0;
      last_done_cycle[port] = 0;
      for (int unsigned id = 0; id < NUM_IDS; id++) begin
        read_busy[port][id]  = 1'b0;
        write_busy[port][id] = 1'b0;
      end
    end
    for (int unsigned idx = 0; idx <= NUM_PHASES; idx++) begin
      logged[idx] = 0;
    end
    void'($value$plusargs("SKIP_RESET=%d", skip_reset));
    void'($value$plusargs("DROP_PHASE=%d", drop_phase));
    void'($value$plusargs("PHASES=%d", phase_mask));
    void'($value$plusargs("ALL_PORTS_CYCLES=%d", all_ports_cycles));
    if ($value$plusargs("SEED=%d", seed)) begin
      $display("HBM seed=%0d", seed);
    end
    rng_state = (seed == 0) ? 1 : seed;
    if (phase_mask == 0 || phase_mask > ALL_PHASES) begin
      $fatal(1, "HBM_LATENCY_CONFIG phases=%0d must be 1..%0d", phase_mask, ALL_PHASES);
    end
    if (drop_phase != 0 && !phase_mask[drop_phase-1]) begin
      $fatal(1, "HBM_LATENCY_CONFIG dropped phase %0d is not enabled", drop_phase);
    end
    csv = $fopen("latency.csv", "w");
    if (csv == 0) begin
      $fatal(1, "HBM_LATENCY_FILE cannot open latency.csv");
    end
    $fwrite(csv, "phase,port,dir,seq,addr,tag,valid_cycle,accept_cycle,data_cycle,done_cycle\n");
    if (skip_reset) begin
      rst_n = 1'b1;
    end
    repeat (32) @(negedge apb_clk);
    if (reset_cycles < 32) begin
      $fatal(1, "HBM_RESET_REQUIRED: observed %0d reset cycles", reset_cycles);
    end
    rst_n = 1'b1;
    wait (initialized === 2'b11);
    $display("HBM initialized at %t", $realtime);
    repeat (16) @(negedge axi_clk);
    if (enabled(PhaseIdle)) begin
      run_idle();
    end
    if (enabled(PhaseStride)) begin
      run_stride();
    end
    if (enabled(PhaseDepth)) begin
      run_depth();
    end
    if (enabled(PhaseRandom)) begin
      run_random();
    end
    if (enabled(PhaseAllPorts)) begin
      run_all_ports();
    end
    if (enabled(PhaseMixed)) begin
      run_mixed();
    end
    $fclose(csv);
    $display("F2_HBM_LATENCY_DONE phases=%0d records=%0d cycles=%0d", phase_mask, logged.sum(),
             cycle);
    $finish;
  end
endmodule
