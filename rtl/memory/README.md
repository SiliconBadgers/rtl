# Memory rtl

Storage and data movement implementations developed through the team’s chosen work.

This directory currently contains this structure note. Members can add material when their chosen work needs it.

This is a suggested home for work supporting the [charter](../../docs/memory/CHARTER.md) and
[objectives](../../docs/memory/OBJECTIVES.md). The team can reorganize or extend it as its work
develops. A directory’s presence does not assign a task or require an artifact.

# sram_arbiter

RTL for the SRAM arbiter described in 'docs/memory/sram_arbiter_io_scheme.md'.

## Files

| File | Module | Block |
| --- | --- | --- |
| 'rtl/sram_arbiter_pkg.sv' | 'sram_arbiter_pkg' | Constants, 'req_tag_e', 'mem_req_t', 'vec_lane_tag()' |
| 'rtl/sram_arbiter.sv' | 'sram_arbiter' | Top level, instances 'u_*', assertions |
| 'rtl/sram_arb_priority.sv' | 'sram_arb_priority' | Block 1: MM > Matrix > Vec[lowest] |
| 'rtl/sram_arb_req_mux.sv' | 'sram_arb_req_mux' | Block 2: 'unified_req', tag, address alignment, lane-slice placement |
| 'rtl/sram_arb_addr_decode.sv' | 'sram_arb_addr_decode' | Block 3: 'bank_id', 'bank_offset', 'lane_mask', path enables |
| 'rtl/sram_arb_bank_conflict.sv' | 'sram_arb_bank_conflict' | Block 4: bank-group busy tracking, 'conflict' |
| 'rtl/sram_arb_port_ctrl.sv' | 'sram_arb_port_ctrl' | Block 5: 'can_proceed', '*_req_ready_o', SRAM request, byte enables |
| 'rtl/sram_arb_rsp_route.sv' | 'sram_arb_rsp_route' | Block 6: tag routing, scoreboard completions |
| 'tb/sram_model.sv' | 'sram_model' | Behavioural in-order SRAM with fixed latency (simulation only, no transpose) |
| 'tb/sram_arbiter_tb.sv' | 'sram_arbiter_tb' | Self-checking testbench |



## Parameter

'BankBusyCycles' (default 0): cycles a 128 B bank group stays busy after an access. With 0 the
SRAM accepts one access every cycle and Block 4 never stalls. Set it to match the SRAM wrapper.

## Behaviour notes

- Arbitration and the request path are combinational. Combinational paths:
  '*_req_valid_i -> *_req_ready_o' and 'sram_req_ready_i -> *_req_ready_o'.
- The only state is the Block 4 busy counters ('stall_cycles_q', async active-low reset).
- Responses and completions are passed through combinationally from the SRAM response port.
- Misaligned addresses are forced to the aligned row (Matrix, MM) or lane slice (Vector);
  'MmReqAligned_A', 'MatrixReqAligned_A' and 'VecReqAligned_A' report them in simulation.
- Responses with a tag above 'TagVec3' are dropped; 'RspTagLegal_A' reports them.
- 'sram_transpose_o' passes 'vec_req_transpose_i' through for Vector requests and is 0 otherwise.
  The transpose itself is done by the SRAM side.
- Fixed priority can starve Vector lanes under sustained MM or Matrix traffic.
- Assertions are inside 'ifndef SYNTHESIS'.
- 'sram_arbiter' supports 'NUM_LANES = 4' only; elaboration stops with an error otherwise.
- Reset: the arbiter holds no accepted work. Requests already in the SRAM pipeline must be
  discarded by the SRAM on the same reset.
- Port names 'sb_*' mean scoreboard, as agreed in the I/O scheme; they are not a project prefix.
