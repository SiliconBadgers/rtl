# Matrix unit integration contract

How `bpu_matrix_unit` connects to the top-level controller, the command queues and the
SRAM arbiter. This is the page for the people wiring the unit in: the controller and
SoC owners, the arbiter owner and the verification team. The arithmetic, the record
fields and the output formats are in the [specification](matrix_unit_spec.md); the
wrapper's internal ports and timing are in the [I/O scheme](matrix_unit_io_scheme.md).

Sources it follows: the [command format](../command-format.md), the top-level control
specification (`docs/control/top_level_control_spec.md`, rtl #32), the SRAM arbiter
specification (`docs/memory/sram_arbiter_spec.md`, rtl #32), the merged
`rtl/control/command_queues.sv`, and the controller in soc #14.

## Where it sits

```text
 firmware ──► controller: Matrix window, PAYLOAD[0..15] + two sideband targets, COMMIT
                │
                ▼
          command_queues, queue 1 (Matrix) ──issue_valid/ready/payload──► bpu_matrix_unit
          shared_scoreboard, counter 1  ◄──────────── milestone_inc_o ────┤
          controller engine_idle_i[1]   ◄──────────── idle_o ─────────────┤
          controller engine_fault_i[1]  ◄──────────── fault_o ────────────┤
                                                                          │
          sram_arbiter, Matrix channel  ◄──── matrix_req_* / matrix_rsp_* ┘
            (shared with Memory, higher priority, and Vector, lower)
```

Memory and Vector never connect to the Matrix unit. They meet it through the scoreboard
(each waits on the others' progress) and through the SRAM.

## Build parameters the system must agree on

| Parameter | Value | Why |
| --- | --- | --- |
| `PayloadWidth` (queues, controller, unit) | 512 | The Matrix version-1 record is 512 bits. The controller's checked-in 128-bit configuration cannot carry it; build the controller with `--payload-width 512`. Every unit's record then shares the 512-bit payload, with unused high bits zero. |
| `CounterWidth` | Any (16 checked here) | The unit only publishes increments. The controller's adapter maps the record's 32-bit wait words to it. |
| `DataW`, `SizeW`, address | 4096, 10, 32 | The arbiter's `DATA_WIDTH`, `SIZE_WIDTH`, `ADDR_WIDTH`. |

Estimate, not synthesized: 512-bit payloads cost the controller about 15 × 384 = 5,760
more flops than 128-bit ones (three queues of four plus three staging windows), roughly
0.1 mm² in sky130 at about 20 µm² per flop, and firmware writes 16 payload words per
Matrix command instead of 4.

## Ports

| Port | Dir | Width | Connects to |
| --- | --- | --- | --- |
| `clk_i`, `rst_ni` | in | 1 | The controller's clock and its coordinated reset |
| `cmd_valid_i` | in | 1 | `command_queues.issue_valid_o[1]` |
| `cmd_ready_o` | out | 1 | `command_queues.issue_ready_i[1]` |
| `cmd_payload_i` | in | `PayloadWidth` | `command_queues.issue_payload_o[1]` |
| `milestone_inc_o` | out | 2 | `command_queues.increment_i[1]` |
| `idle_o` | out | 1 | The controller's `engine_idle_i[1]` |
| `fault_o` | out | 1 | The controller's `engine_fault_i[1]` |
| `matrix_req_valid_o`, `matrix_req_ready_i` | out, in | 1 | Arbiter `matrix_req_valid_i`, `matrix_req_ready_o` |
| `matrix_req_is_write_o` | out | 1 | Arbiter `matrix_req_is_write_i` |
| `matrix_req_size_bytes_o` | out | `SizeW` | Arbiter `matrix_req_size_bytes_i` |
| `matrix_req_addr_o` | out | 32 | Arbiter `matrix_req_addr_i` |
| `matrix_req_wdata_o` | out | `DataW` | Arbiter `matrix_req_wdata_i` |
| `matrix_req_transpose_o` | out | 1 | Arbiter `matrix_req_transpose_i`; always 0 |
| `matrix_req_element_width_o` | out | 2 | Arbiter `matrix_req_element_width_i`; always 0 |
| `matrix_rsp_valid_i`, `matrix_rsp_rdata_i` | in | 1, `DataW` | Arbiter `matrix_rsp_valid_o`, `matrix_rsp_rdata_o` |

## Commands

- **Handshake.** A record transfers on a rising edge with `cmd_valid_i` and `cmd_ready_o`
  both high. `cmd_ready_o` depends only on registers, so the queue can hold valid and
  the payload as long as it likes; the queue already never retracts an offer.
- **One at a time** (`CmdDepth = 1`). The unit accepts the next record in the cycle after
  the previous command completes, or at once if it is idle.
- **The record.** Bits 511:0 are the version-1 record (specification, "Command record").
  With a wider payload, every bit above 511 must be zero.
- **Wait targets.** The record's words 1 and 2 are ignored. The queue has already enforced
  the sideband targets before the record reaches the unit. The controller's adapter
  should still write the same targets into the record so that firmware has one encoding.

## Milestones

Each accepted legal command publishes exactly three milestones, in order. For the j-th
Matrix command since reset (from zero), software waits on these progress values, modulo
`2^CounterWidth`:

| Target | Milestone | What it guarantees |
| --- | --- | --- |
| `3j + 1` | Inputs released | Every SRAM read of A, B and both scale tables has returned. A producer may overwrite those buffers once this is counted. |
| `3j + 2` | Next contribution ready | The unit can accept the next command. With `CmdDepth = 1` it is published together with complete. |
| `3j + 3` | Complete | Every C write has committed: a read accepted after the edge that counts it sees C. Kept sums have settled. |

On `milestone_inc_o`, `00`, `01` and `10` add zero, one or two milestones this cycle;
`11` is never driven. The scoreboard counts on the rising edge. "Complete" is counted no
earlier than the commit edge of the command's last write. An illegal command publishes
nothing.

## Idle

`idle_o` is high when no command is running and no milestone is held or on
`milestone_inc_o`. This is the controller's definition: each idle input covers accepted
work, pending output writes and unpublished milestones. It goes low in the cycle after a
legal command is accepted. It goes high again in the cycle after that command's last
milestone was on `milestone_inc_o`, so the scoreboard has counted it by then. It depends
only on registers and is high in reset.

The wrapper's `busy_o` would not do. It falls in the same cycle as `done_o`, while the
last two milestones are still on `milestone_inc_o`.

## Faults

An illegal command is accepted and then:
- `fault_o` goes high in the next cycle and stays high until reset;
- `cmd_ready_o` stays low, so an offer the controller keeps valid after the fault is
  never accepted;
- it makes no SRAM request and publishes no milestone, and nothing else is running.

"Illegal" covers:
- a malformed record (wrong kind or version, a nonzero reserved bit, a format above 4,
  fractional bits above 31, either transpose bit);
- a nonzero payload bit above 511;
- anything the wrapper rejects: shape, alignment, a feature the build lacks, or a
  continuation that does not match the kept sums.

Correct software never issues one.

The arbiter reports its own faults on its own `fault_o`, for example an address outside
the SRAM. If the arbiter withholds a Matrix request after faulting, the unit stays busy
(`idle_o` low) until reset. The controller already latches the arbiter's fault and
resets everything.

## Reset

Reset the unit together with the queues, the scoreboard counter and the arbiter: the
controller's coordinated reset.

Reset:
- cancels the running command, with no milestones for it;
- discards kept sums;
- clears the fault;
- returns `idle_o` and `cmd_ready_o` high.

The arbiter must cancel a write that has not reached its commit edge and drop any read
response still in flight. C bytes already committed stay in the SRAM, so an interrupted
tile can be partly written.

## SRAM channel

| Item | Contract |
| --- | --- |
| Accesses | Ordinary row accesses only; transpose and element width are always 0. |
| Addresses | Row aligned. The unit rejects a command whose base addresses are not. |
| Reads | `size_bytes` is one row (512 bytes), or the bytes left for an operand's last read, never 0. The unit uses only the bytes it asked for; the arbiter may return the whole row. |
| Read timing | Responses in request order, any latency of one cycle or more, no backpressure. The unit issues a read only when it has room for the response. |
| Writes | Up to one SRAM row of C per request; `size_bytes` covers exactly those bytes, written as a row prefix. |
| Write timing | A write accepted on edge `n` must be committed and visible by edge `n + 1`. The unit has no write acknowledgment and relies on this rule for "complete" and `idle_o`. |
| Stability | A request and its payload stay unchanged until accepted, and depend only on registers. |

## What other blocks still need

- **SRAM arbiter (rtl #35 at `ea35ff9`).** Add the Matrix `matrix_req_transpose_i` and
  `matrix_req_element_width_i` inputs and the sticky `fault_o`, and remove the
  write-done output the specification dropped. Until then, the integration bench uses
  a specification model of the arbiter.
- **Controller (soc #14).** Build with `PayloadWidth = 512`. The command adapter writes
  the Matrix record's wait words consistently with the sideband targets.
- **Memory and Vector units.** None is in rtl yet. The integration bench uses stand-ins
  that follow the Memory unit specification's record and milestones.

## Verification

All benches are in `tb/compute/Matrix_Unit` and run by `run_tests.sh`.

| Bench | Configurations | What it shows |
| --- | --- | --- |
| `bpu_matrix_unit_tb` | `top_8x8_payload512`; `top_8x8_payload640_lat1` (the arbiter's exact 1-cycle reads, always ready) | Real Qwen3.5-2B tensors sent as version-1 records through the decoder and wrapper, bit-exact. Wait words carry random junk and are ignored. Three illegal records each give a sticky fault with no traffic and no milestones, and a held legal offer is refused for 40 cycles. The 640-bit configuration adds a high payload bit. Recovery after each fault and after a mid-command reset. `idle_o` is checked every cycle against three milestones per accepted command. |
| `bpu_matrix_unit_system_tb` | `system_8x8_stall20`; `system_8x8_nostall` | The real `command_queues` with the unit, a specification model of the arbiter (Memory > Matrix > Vector, 1-cycle completion, random busy cycles) and Memory and Vector stand-ins. Matrix waits for loads. A transfer waits only for the last command's input release and then overwrites that command's B operand. A Vector run waits for Matrix complete and reads C back bit-exact. Completion is decided as the controller does. A malformed record faults while the queue keeps offering the next one. Reset in mid-job, then a clean rerun on the same hardware. |
| `bpu_sa_sram_wrapper_tb` | all `wrap_*` | Also checks the wrapper's `idle_o` every cycle against its own milestone count. |

Planted bugs, each of which must make the listed benches fail, are recorded in the
pull request with the results for the tested commit.
