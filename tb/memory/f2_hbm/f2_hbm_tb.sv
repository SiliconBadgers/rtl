module f2_hbm_tb;
  timeunit 1ns; timeprecision 1ps;

  localparam int unsigned NUM_PORTS = 32;
  localparam int unsigned BURST_LENGTHS[3] = '{1, 4, 16};
  localparam int unsigned EXPECTED_BEATS = NUM_PORTS * (1 + 4 + 16);
  localparam int unsigned EXPECTED_BURSTS = NUM_PORTS * 3;
  logic axi_clk = 1'b0;
  logic apb_clk = 1'b0;
  logic rst_n = 1'b0;
  wire [1:0] initialized;
  logic [NUM_PORTS-1:0][33:0] awaddr, araddr;
  logic [NUM_PORTS-1:0][3:0] awlen, arlen;
  logic [NUM_PORTS-1:0][5:0] awid, arid;
  logic [NUM_PORTS-1:0] awvalid, arvalid, wvalid, wlast, bready, rready;
  logic [NUM_PORTS-1:0][255:0] wdata;
  wire [NUM_PORTS-1:0] awready, arready, wready, bvalid, rvalid, rlast;
  wire [NUM_PORTS-1:0][255:0] rdata;
  wire [NUM_PORTS-1:0][5:0] bid, rid;
  wire [NUM_PORTS-1:0][1:0] bresp, rresp;
  int unsigned seed = 1;
  int unsigned written_beats = 0;
  int unsigned checked_beats = 0;
  int unsigned checked_responses = 0;
  int unsigned read_stall_cycles = 0;
  int unsigned write_response_stall_cycles = 0;
  int unsigned reset_cycles = 0;
  bit skip_backpressure;
  bit skip_reset = 1'b0;
  bit corrupt_expected = 1'b0;

  always #1.111ns axi_clk = ~axi_clk;
  always #5ns apb_clk = ~apb_clk;

  // The native interface exposes 32 ports with distinct names. Keep that mapping
  // here so traffic and scoreboarding use channel-indexed arrays.
  `define CONNECT_AXI(P, N) \
  .AXI_``P``_ACLK(axi_clk), \
  .AXI_``P``_ARESET_N(rst_n), \
  .AXI_``P``_AWADDR(awaddr[N]), \
  .AXI_``P``_AWBURST(2'b01), \
  .AXI_``P``_AWID(awid[N]), \
  .AXI_``P``_AWLEN(awlen[N]), \
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
  .AXI_``P``_BREADY(bready[N]), \
  .AXI_``P``_ARADDR(araddr[N]), \
  .AXI_``P``_ARBURST(2'b01), \
  .AXI_``P``_ARID(arid[N]), \
  .AXI_``P``_ARLEN(arlen[N]), \
  .AXI_``P``_ARSIZE(3'd5), \
  .AXI_``P``_ARVALID(arvalid[N]), \
  .AXI_``P``_ARREADY(arready[N]), \
  .AXI_``P``_RDATA(rdata[N]), \
  .AXI_``P``_RDATA_PARITY(), \
  .AXI_``P``_RID(rid[N]), \
  .AXI_``P``_RRESP(rresp[N]), \
  .AXI_``P``_RLAST(rlast[N]), \
  .AXI_``P``_RVALID(rvalid[N]), \
  .AXI_``P``_RREADY(rready[N])

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

  // Each macro below expands to named ports on the vendor's 32-channel interface.
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
    ReadStable_A :
    assert property (
      @(posedge axi_clk) disable iff (!rst_n)
      rvalid[port_idx] && !rready[port_idx] |=>
      rvalid[port_idx] && $stable(
      {rdata[port_idx], rid[port_idx], rresp[port_idx], rlast[port_idx]}
    ))
    else $fatal(1, "HBM read response changed while stalled on port %0d", port_idx);
    WriteResponseStable_A :
    assert property (
      @(posedge axi_clk) disable iff (!rst_n)
      bvalid[port_idx] && !bready[port_idx] |=>
      bvalid[port_idx] && $stable(
      {bid[port_idx], bresp[port_idx]}
    ))
    else $fatal(1, "HBM write response changed while stalled on port %0d", port_idx);
  end

  always @(posedge axi_clk) begin
    if (!rst_n) begin
      reset_cycles++;
    end else begin
      for (int unsigned port_idx = 0; port_idx < NUM_PORTS; port_idx++) begin
        if (rvalid[port_idx] && !rready[port_idx]) begin
          read_stall_cycles++;
        end
        if (bvalid[port_idx] && !bready[port_idx]) begin
          write_response_stall_cycles++;
        end
      end
    end
  end

  function automatic logic [255:0] pattern(
    input int unsigned port_idx, input int unsigned burst_idx, input int unsigned beat_idx);
    logic [255:0] result;
    for (int unsigned word_idx = 0; word_idx < 8; word_idx++) begin
      result[32*word_idx+:32] = seed ^ (port_idx << 24) ^ (burst_idx << 20) ^
                                (beat_idx << 8) ^ (32'h9e37_79b9 * (word_idx + 1));
    end
    return result;
  endfunction

  // Each pseudo-channel owns 512 MiB in the F2 global address map. Keep burst
  // regions disjoint and read only after every channel has been written.
  function automatic logic [33:0] address(input int unsigned port_idx,
                                          input int unsigned burst_idx);
    return (34'(port_idx) << 29) | (34'(burst_idx) << 12);
  endfunction

  task automatic write_burst(input int unsigned port_idx, input int unsigned burst_idx);
    @(negedge axi_clk);
    awaddr[port_idx] = address(port_idx, burst_idx);
    awlen[port_idx] = 4'(BURST_LENGTHS[burst_idx] - 1);
    awid[port_idx] = 6'(port_idx + burst_idx);
    awvalid[port_idx] = 1'b1;
    do begin
      @(posedge axi_clk);
    end while (awready[port_idx] !== 1'b1);
    @(negedge axi_clk);
    awvalid[port_idx] = 1'b0;
    for (int unsigned beat_idx = 0; beat_idx < BURST_LENGTHS[burst_idx]; beat_idx++) begin
      wdata[port_idx]  = pattern(port_idx, burst_idx, beat_idx);
      wlast[port_idx]  = (beat_idx == BURST_LENGTHS[burst_idx] - 1);
      wvalid[port_idx] = 1'b1;
      do begin
        @(posedge axi_clk);
      end while (wready[port_idx] !== 1'b1);
      written_beats++;
      @(negedge axi_clk);
    end
    wvalid[port_idx] = 1'b0;
    wlast[port_idx]  = 1'b0;
    if (!skip_backpressure) begin
      wait (bvalid[port_idx] === 1'b1);
      repeat (4) @(negedge axi_clk);
    end
    bready[port_idx] = 1'b1;
    do begin
      @(posedge axi_clk);
    end while (bvalid[port_idx] !== 1'b1);
    if (bresp[port_idx] !== 2'b00 || bid[port_idx] !== awid[port_idx]) begin
      $fatal(1, "HBM_WRITE_RESPONSE port=%0d response=%h id=%h", port_idx, bresp[port_idx],
             bid[port_idx]);
    end
    checked_responses++;
    @(negedge axi_clk);
    bready[port_idx] = skip_backpressure;
  endtask

  task automatic read_burst(input int unsigned port_idx, input int unsigned burst_idx);
    logic [255:0] expected;
    @(negedge axi_clk);
    araddr[port_idx] = address(port_idx, burst_idx);
    arlen[port_idx] = 4'(BURST_LENGTHS[burst_idx] - 1);
    arid[port_idx] = 6'(port_idx + burst_idx);
    arvalid[port_idx] = 1'b1;
    do begin
      @(posedge axi_clk);
    end while (arready[port_idx] !== 1'b1);
    @(negedge axi_clk);
    arvalid[port_idx] = 1'b0;
    for (int unsigned beat_idx = 0; beat_idx < BURST_LENGTHS[burst_idx]; beat_idx++) begin
      if (!skip_backpressure) begin
        wait (rvalid[port_idx] === 1'b1);
        repeat (3) @(negedge axi_clk);
      end
      rready[port_idx] = 1'b1;
      do begin
        @(posedge axi_clk);
      end while (rvalid[port_idx] !== 1'b1);
      expected = pattern(port_idx, burst_idx, beat_idx);
      if (corrupt_expected) begin
        expected[0] = ~expected[0];
      end
      if (rdata[port_idx] !== expected) begin
        $fatal(1, "HBM_DATA_MISMATCH port=%0d burst=%0d beat=%0d got=%h expected=%h", port_idx,
               burst_idx, beat_idx, rdata[port_idx], expected);
      end
      if (rresp[port_idx] !== 2'b00 || rid[port_idx] !== arid[port_idx] ||
          rlast[port_idx] !== (beat_idx == BURST_LENGTHS[burst_idx] - 1)) begin
        $fatal(1, "HBM_READ_RESPONSE port=%0d burst=%0d beat=%0d", port_idx, burst_idx, beat_idx);
      end
      checked_beats++;
      @(negedge axi_clk);
      rready[port_idx] = skip_backpressure;
    end
  endtask

  initial begin : watchdog
    #1ms;
    $fatal(1, "HBM_TIMEOUT initialized=%b writes=%0d reads=%0d", initialized, written_beats,
           checked_beats);
  end

  initial begin : stimulus
    awaddr = '0;
    araddr = '0;
    awlen = '0;
    arlen = '0;
    awid = '0;
    arid = '0;
    awvalid = '0;
    arvalid = '0;
    wvalid = '0;
    wlast = '0;
    wdata = '0;
    skip_backpressure = 1'b0;
    void'($value$plusargs("SKIP_BACKPRESSURE=%d", skip_backpressure));
    void'($value$plusargs("SKIP_RESET=%d", skip_reset));
    void'($value$plusargs("CORRUPT_EXPECTED=%d", corrupt_expected));
    if (skip_reset) begin
      rst_n = 1'b1;
    end
    bready = {NUM_PORTS{skip_backpressure}};
    rready = {NUM_PORTS{skip_backpressure}};
    if ($value$plusargs("SEED=%d", seed)) begin
      $display("HBM seed=%0d", seed);
    end
    repeat (32) @(negedge apb_clk);
    if (reset_cycles < 32) begin
      $fatal(1, "HBM_RESET_REQUIRED: observed %0d reset cycles", reset_cycles);
    end
    rst_n = 1'b1;
    wait (initialized === 2'b11);
    $display("HBM initialized at %t", $realtime);
    repeat (16) @(negedge axi_clk);
    for (int unsigned port_idx = 0; port_idx < NUM_PORTS; port_idx++) begin
      for (int unsigned burst_idx = 0; burst_idx < 3; burst_idx++) begin
        write_burst(port_idx, burst_idx);
      end
    end
    for (int unsigned port_idx = 0; port_idx < NUM_PORTS; port_idx++) begin
      for (int unsigned burst_idx = 0; burst_idx < 3; burst_idx++) begin
        read_burst(port_idx, burst_idx);
      end
    end
    if (read_stall_cycles == 0 || write_response_stall_cycles == 0) begin
      $fatal(1, "HBM_BACKPRESSURE_REQUIRED: read=%0d write=%0d", read_stall_cycles,
             write_response_stall_cycles);
    end
    if (written_beats != EXPECTED_BEATS || checked_beats != EXPECTED_BEATS ||
        checked_responses != EXPECTED_BURSTS) begin
      $fatal(1, "HBM_COUNT_MISMATCH writes=%0d reads=%0d responses=%0d", written_beats,
             checked_beats, checked_responses);
    end
    $display({"F2_HBM_PASS ports=%0d writes=%0d reads=%0d responses=%0d ",
              "reset_cycles=%0d read_stalls=%0d write_stalls=%0d"}, NUM_PORTS, written_beats,
               checked_beats, checked_responses, reset_cycles, read_stall_cycles,
               write_response_stall_cycles);
    $finish;
  end
endmodule
