# Command queues and shared scoreboard

Three reusable RTL blocks implement FIFO-head dependency gating. They remain
separate from the provisional `command_router`/`command_pkg`: no binary ABI,
command decoder, host interface, engine datapath, or SoC integration is added.

## Modules and parameters

- `command_queue.sv`: one FIFO for an opaque payload and two wait targets. It
  exposes its head targets and accepts a dependency-ready result; it contains
  neither counters nor comparisons
- `shared_scoreboard.sv`: `NumCounters` wrapping progress counters and exactly two
  statically mapped comparisons per FIFO head; no command storage
- `command_queues.sv`: `NumQueues` generated queue instances wired to one shared
  scoreboard, with independent array-indexed input and engine-issue channels

All use positive integer width/depth parameters where applicable:
`QueueDepth=4`, `PayloadWidth=32`, and `CounterWidth=16`. Defaults are block-level
choices, not a frozen hardware configuration. The wrapper uses a common depth
and payload width; the individual queue can be reused with different settings.
Payload fields and wait targets are supplied separately by an external decoder.

| FIFO | Target 0 | Target 1 |
| --- | --- | --- |
| Memory | Matrix progress | Vector progress |
| Matrix | Memory progress | Vector progress |
| Vector | Memory progress | Matrix progress |

## Parameterized interface and migration (October 19, 2026)

`command_queues` and `shared_scoreboard` add `NumQueues=3`, `NumCounters=3`,
`WaitCounter0[NumQueues]`, and `WaitCounter1[NumQueues]`. Parameter names follow
this project's UpperCamelCase convention. Both counts must be positive; neither
must equal the other. `command_queue.sv` is byte-for-byte unchanged.

There are still exactly two wait targets per command, not an all-to-all wait
vector. Each mapping entry selects a counter index in `[0, NumCounters-1]` at
elaboration. `-1` selects the legacy mapping in the table above for queue indices
0=Memory, 1=Matrix, 2=Vector. For additional queues, both entries must be supplied
explicitly. Any unresolved or out-of-range mapping fails a startup assertion;
no invalid array reference is elaborated. Even a slot whose runtime target is
always zero requires a valid static mapping. Other negative indices are invalid.

Queue and counter namespaces are independent. Multiple queues may wait on the
same counter, and both slots may select the same counter. No self-dependency or
cycle detector is provided. Integrators own a meaningful dependency graph and
one correctly aggregated, ordered increment source per counter; this module
neither merges engine increments nor assigns queues to engines.

All new array dimensions are **unpacked**, zero-based ascending `[0:Count-1]`
(written `[Count]` in SV). Payloads, targets, increments and progress values
remain packed bit vectors inside those arrays. Connect matching unpacked arrays,
not packed vectors or reversed concatenations.

This is a port-interface change, not a drop-in replacement for old named ports:

- Old `memory_push_valid_i` becomes `push_valid_i[0]`, Matrix uses `[1]`, Vector
  uses `[2]`; likewise map `push_ready_o`, `push_payload_i`, both
  `push_wait_target_0_i` / `push_wait_target_1_i`, `issue_valid_o`,
  `issue_ready_i`, and `issue_payload_o`
- Old `memory_increment_i` / `memory_progress_o` become `increment_i[0]` /
  `progress_o[0]`, Matrix uses `[1]`, Vector uses `[2]`
- Standalone scoreboard users must likewise migrate to `increment_i`,
  `wait_target_0_i`, `wait_target_1_i`, `dependencies_met_o`, and `progress_o`
- Replace wrapper and scoreboard together. Existing standalone FIFO users need
  no edits. Old named-port testbenches need migration before compilation

For example, four queues sharing the original three progress counters, with
queue 3 explicitly waiting on Memory and Vector, use these parameter overrides:

```systemverilog
.NumQueues(4),
.NumCounters(3),
.WaitCounter0('{1, 0, 0, 0}),
.WaitCounter1('{2, 2, 1, 2})
```

A one-queue, one-counter configuration can explicitly map both slots to zero:

```systemverilog
.NumQueues(1),
.NumCounters(1),
.WaitCounter0('{0}),
.WaitCounter1('{0})
```

The example maps are integration choices, not new architectural requirements.
Changing `NumQueues` alone to 1 or 2 retains the original three-counter namespace
and the corresponding first one or two legacy queues. Adding counters requires
explicit increment sources; adding queues beyond index 2 requires explicit maps.
With defaults there are three counters and six comparisons, exactly as before.

## Progress and dependency interface

All ports share rising-edge `clk_i`. Each counter producer supplies a two-bit encoded
increment per cycle: `00=0`, `01=1`, `10=2`. `11` or unknown encodings trigger a
fatal assertion in simulation. The hardware default holds the affected counter
on an illegal encoding; this is not an error-recovery mechanism.

The interface permits a maximum of two milestones **per counter per cycle**.
The original mapping assumes one counter per engine. Whether the intended
architectural limit is instead two total across all engines is still open. There is no global event arbiter or aggregate-rate assertion.

Counters start at zero and count milestones, not commands or FIFO occupancy.
Increments are sampled once every active edge, with no handshake or event buffer.
Engines own exactly-once, command-ordered publication and event retention. For
example, three coincident ordered Matrix milestones require the producer to
retain at least one for a later cycle. This block cannot detect duplicate or
out-of-order events from an encoded count alone.

A target of zero disables the wait. Otherwise compute
`delta = (progress - target) modulo 2^CounterWidth`; the wait is met when delta's
top bit is clear. The exact half-range boundary is not met. Software must keep
live dependencies within half the range and cannot use zero as a real target,
even when a milestone wraps to zero.

Comparisons use registered counters with no same-cycle increment bypass. An
increment sampled at an edge can make a queued head valid during the following
cycle; that command can handshake at the next edge.

## FIFO and handshake contract

- A transfer occurs at a rising edge with valid and ready asserted. Producers
  must hold valid and all input fields stable while stalled
- Capacity is `QueueDepth` accepted, not-yet-issued commands. Heads issue in FIFO
  order only after both dependencies pass; blocked heads cannot be bypassed
- No fallthrough: a push into an empty queue cannot issue on the same edge
- Nonempty, nonfull queues support simultaneous push and issue
- Full queues deassert push ready even when popping. A replacement is accepted
  no earlier than the next cycle; depth-one queues therefore have a throughput
  limit of one accepted command every two cycles
- Pointer wrap supports depth one and non-power-of-two depths
- Once a head is offered while stalled, eligibility is retained until issue or
  reset. Counter movement/wrap cannot retract valid or change payload/targets
- Empty queues drive head targets and payload to zero. Payload while issue valid
  is low is otherwise not meaningful

Engine `issue_ready_i` owns execution capacity and same-engine compatibility.
The queue does not schedule engine latency or generate milestones. The intended
combinational path is head targets through the shared scoreboard to issue valid;
push ready depends only on reset and registered occupancy, never engine ready.
Integrators must avoid handshake loops in their surrounding logic.

## Reset and open integration decisions

`rst_ni` is asynchronous active-low reset. The parent must deassert it
synchronously to `clk_i`. Reset clears queue occupancy, pointers, retained offers,
and counters; payload arrays are not reset. Push ready and issue valid are low
while reset is asserted. Queued and offered/stalled commands are cancelled,
without replay or completion.

Already-issued engine work is external. The system must cancel or drain it and
suppress stale pre-reset milestone pulses so engines and counters restart in the
same epoch. There is no independent flush, quiesce, selective counter reset,
error completion, or event retry interface. Those recovery semantics, the
per-engine versus global increment limit, final widths/depths, and binary command
packing must be settled before system integration.

## Basis and verification status

The local implementation starts at RTL main
[`c1e9dcf`](https://github.com/SiliconBadgers/rtl/commit/c1e9dcf7f205994270204132cd87c62781176333),
using the refreshed [command format specification](https://github.com/SiliconBadgers/rtl/blob/182e7f8365ae1a2936242e59436f89bb31eed6b0/docs/command-format.md)
and [shared decisions](https://github.com/SiliconBadgers/architecture/blob/a04c9acd612af51fe6a8c79273d989a782c3f0cc/decisions/command-format-decisions.md).
Both specification documents were still on proposal branches at implementation
time. The two-bit increment contract incorporates the subsequent implementation
requirement; the per-engine interpretation remains an assumption.

No SystemVerilog compile,
RTL simulation, formal, synthesis, timing, CDC/reset analysis, or pinned style
check has passed for these new modules in this workspace. VCS and the pinned
Verible/Ruff tools are absent. Repository policy requires VCS Y-2026.03_Full64 for
RTL simulation; no alternate simulator was used. See `SETUP.md` for tool setup.

For this parameterization revision, `make style` was attempted and blocked by
missing `verible-verilog-format`. `python3 scripts/vcs.py check` was attempted
and correctly failed because VCS is unavailable. No software was installed.
Source-level checks confirmed the FIFO and scoreboard arithmetic helper functions
are unchanged, the original default mapping is retained, and invalid mapping
branches avoid out-of-range counter references. These checks are not HDL
compilation, elaboration or simulation. No functional pass or coverage is claimed.
