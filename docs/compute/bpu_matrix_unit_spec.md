# `bpu_matrix_unit` specification

**Version 1.0, 2026-11-22.** It describes
`rtl/compute/Matrix_Unit/bpu_matrix_unit.sv` and the modules it instantiates (the source list
is `rtl/compute/Matrix_Unit/bpu_sa_array.f`) as of rtl commit `769219b`, the last change to the
unit's behaviour. It follows the [spec style guide](../spec-style-guide.md).

Normative parts of the [I/O scheme](matrix_unit_io_scheme.md), section 2: "Chaining commands
along K", "Memory layout" (with "Output encodings") and "Arithmetic". They define C; this
document defines everything at the unit's ports. The executable reference for C is the golden
model's contract mode, `golden/matrix_v1.py` in SiliconBadgers/verification
`models/golden_kquant`.

Sources it follows: the control and SRAM arbiter specifications in rtl #32 (not merged), the
merged `rtl/control/command_queues.sv` (#29), and the controller in soc #14. Each requirement's
tests are in [bpu_matrix_unit_requirements.csv](bpu_matrix_unit_requirements.csv), in the
verification repository's `plans/requirements-template.csv` columns.

## 1. Summary

`bpu_matrix_unit` computes one tile of `C = A · B` per command on a `Rows × Cols`
output-stationary systolic array. A is INT8; B is INT8 or packed INT4. A command sums
exactly in integers, or with block scaling: bf16 scales for every `BlockK` values of K, summed
in a 48-bit fixed-point accumulator per element. C is written in one of five encodings. Long
dot products can be split across commands that keep their sums in the array.

Commands arrive as 512-bit version-1 records from the Matrix command queue, one at a time. The
unit reports three progress milestones per command, an idle signal and a sticky fault to the
controller. It reads its operands and writes C through the SRAM arbiter's Matrix channel.

## 2. Block diagram

```text
                     ┌──────────────────────────── bpu_matrix_unit ───────────────────────────┐
 command queue ─────►│ cmd_payload_i[511:0] ─► bpu_sa_command_decoder ─► bpu_sa_sram_wrapper  │
  (issue port 1)     │ any bit above 511 ──────────────────────────────►  (illegal)           │
                     │                                                    │  ▲               │
                     │   fault_q ◄── err_o (sticky)                        │  │ 4 read streams│
 controller ◄────────│ fault_o, idle_o, milestone_inc_o                   ▼  │ C write-back  │
                     │                                       bpu_sa_array (Rows × Cols PEs)    │
                     │                                       bpu_sa_output_convert             │
 SRAM arbiter ◄─────►│ matrix_req_* / matrix_rsp_*  (transpose and element width tied to 0)   │
  (Matrix channel)   └────────────────────────────────────────────────────────────────────────┘
```

Memory and Vector never connect to the unit. They meet it through the scoreboard (each waits on
the others' progress) and through the SRAM.

Figures: [ports](matrix_unit/svg/matrix_unit_ports.svg), [blocks and assertion map](matrix_unit/svg/matrix_unit_structure.svg), [hierarchy and wiring](matrix_unit/svg/matrix_unit_hierarchy.svg), [one block-scaled command](matrix_unit/svg/matrix_unit_timeline.svg).

## 3. Parameters

| Parameter | Default | Valid range | Meaning |
| --- | --- | --- | --- |
| `PayloadWidth` | 512 | ≥ 512, a multiple of 32 | Width of `cmd_payload_i`, the system's queue payload. |
| `Rows` | 8 | A power of two, 1 to `DataW/8`; at most `DataW/16` when `Int4` or `Scale` is 1 | Rows of the C tile (M). |
| `Cols` | 8 | A power of two, 1 to `DataW/32`; at least 2 when `Int4` is 1 | Columns of the C tile (N). |
| `AccW` | 32 | 16 to 32; with `Scale`, at least `log2(BlockK) + 16` and at least 25 | Integer accumulator width. Unscaled sums are exact while K < 2^(`AccW` − 15). |
| `DataW` | 4096 | 8 × a power of two | SRAM row in bits; the arbiter's `DATA_WIDTH`. |
| `SizeW` | 10 | 2^`SizeW` > `DataW/8` | Width of `matrix_req_size_bytes_o`; the arbiter's `SIZE_WIDTH`. |
| `BufRows` | 2 | ≥ 1 | SRAM rows buffered per read stream. |
| `Int4` | 1 | 0 or 1 | Build the INT4-weight mode. |
| `Scale` | 1 | 0 or 1 | Build block scaling. |
| `BlockK` | 16 | A power of two, 16 to 1024 (checked when `Scale` is 1) | Values of K per scale block. |
| `OutDepth` | 9 | ≥ 1 | Finished C rows queued for write-back. |

Fixed inside the unit: byte addresses are 32 bits, and K is 16 bits (1 to 65,535).

Outside its range, a parameter stops simulation at time 0 with `$fatal`. Synthesis does not
check (L4). The system builds the unit with `PayloadWidth` 512, `DataW` 4096 and `SizeW` 10,
the values of the queues and the arbiter (AS8, AS9).

## 4. Clocks and resets

- One clock, `clk_i`; everything acts on its rising edge. Every port is synchronous to it.
- `rst_ni` is active low. It asserts asynchronously and deasserts synchronously to `clk_i`
  (AS1).
- **Reset resets** all control state:
  - the running command is cancelled, and it publishes no further milestones;
  - kept sums are discarded;
  - the fault is cleared;
  - held milestones and every request valid are cleared.
- **Reset does not reset** data storage: the read buffers, the PE accumulators, the C staging
  register and the write-back queue. Their contents are never used before they are written
  again.
- **During reset and in the first cycle after it:** `idle_o` = 1, `fault_o` = 0,
  `cmd_ready_o` = 1, `milestone_inc_o` = 00, `matrix_req_valid_o` = 0.
- The unit is reset together with the command queues, the scoreboard counter and the arbiter:
  the controller's coordinated reset (AS2).

## 5. Ports

| Port | Dir | Width | Description |
| --- | --- | --- | --- |
| `clk_i` | in | 1 | Clock |
| `rst_ni` | in | 1 | Active-low reset |
| `cmd_valid_i` | in | 1 | A record is offered. From `command_queues.issue_valid_o[1]` |
| `cmd_ready_o` | out | 1 | The unit accepts the record on this edge. To `issue_ready_i[1]` |
| `cmd_payload_i` | in | `PayloadWidth` | The record in bits 511:0; higher bits must be 0. From `issue_payload_o[1]` |
| `milestone_inc_o` | out | 2 | Milestones published this cycle: 00, 01 or 10. To `increment_i[1]` |
| `idle_o` | out | 1 | No accepted work, held milestone or pending write. To the controller's `engine_idle_i[1]` |
| `fault_o` | out | 1 | Sticky fault. To the controller's `engine_fault_i[1]` |
| `matrix_req_valid_o` | out | 1 | Request to the arbiter's Matrix channel |
| `matrix_req_ready_i` | in | 1 | The arbiter accepts the request on this edge |
| `matrix_req_is_write_o` | out | 1 | 1 write, 0 read |
| `matrix_req_size_bytes_o` | out | `SizeW` | Bytes in the request, 1 to `DataW/8` |
| `matrix_req_addr_o` | out | 32 | Row-aligned byte address |
| `matrix_req_wdata_o` | out | `DataW` | Write data; byte n goes to address + n |
| `matrix_req_transpose_o` | out | 1 | Always 0 |
| `matrix_req_element_width_o` | out | 2 | Always 00 |
| `matrix_rsp_valid_i` | in | 1 | One pulse per completed read |
| `matrix_rsp_rdata_i` | in | `DataW` | Read data; byte n is the byte at the request address + n |

## 6. Register map

None. Software reaches the unit only through the command record (7.1).

## 7. Functional description

### 7.1 Programming model

For the j-th legal Matrix command since reset, counting from 0:

1. Place A, B and, when block-scaled, the scale tables sA and sB in SRAM in the layout of the
   I/O scheme ("Memory layout"), for example with Memory unit transfers.
2. Write the 16 record words (7.2) into the controller's Matrix window, with the sideband wait
   targets. The Memory target is the Memory progress value that covers those loads. Write the
   same targets into record words 1 and 2. Then commit.
3. Wait on Matrix progress `3j + 1` (modulo 2^`CounterWidth`) before overwriting A, B, sA or
   sB, and on `3j + 3` before reading C.
4. To split K across commands, use `clear_acc` / `write_output` 1/0 for the first part, 0/0
   for middle parts and 0/1 for the last part, with the same M, N and kind (unscaled or
   block-scaled) throughout.
5. The job is finished, and the unit idle, when every final target is reached, every queue is
   empty and every engine's idle input, including `idle_o`, is 1.
6. If the controller reports an engine fault, the job is lost: apply the coordinated reset
   and issue the commands again from step 1. Kept sums are lost; C may be partly written.

### 7.2 Operation

**The record.** Bits 511:0 of `cmd_payload_i`. Word w is bits `32w + 31 : 32w`; bit ranges in
the table are local to each word. Every reserved bit must be 0.

| Word | Bits | Field |
| --- | --- | --- |
| 0 | 1:0 | Kind: 1 (Matrix) |
| 0 | 15:8 | Version: 1. Other word-0 bits are reserved. |
| 1 | 31:0 | Memory wait target (ignored by the unit) |
| 2 | 31:0 | Vector wait target (ignored by the unit) |
| 3, 4, 5 | 31:0 | A, B and C byte addresses |
| 6, 7 | 31:0 | Activation-scale (sA) and weight-scale (sB) byte addresses |
| 8 | 15:0, 31:16 | M, N |
| 9 | 15:0 | K |
| 9 | 16, 17 | Transpose A, transpose B (must be 0) |
| 9 | 18, 19 | `clear_acc`, `write_output` |
| 9 | 20, 21 | INT4 weights, block-scaled |
| 9 | 24:22 | Output encoding: 0 legacy, 1 INT32, 2 FP32, 3 FP16, 4 INT8 |
| 9 | 30:25 | INT32 fractional bits, 0 to 31 |
| 9 | 31 | Reserved |
| 10 | 31:0 | Unsigned requantization multiplier |
| 11 | 6:0 | Unsigned requantization right shift; bits 31:7 reserved |
| 12–15 | 31:0 | Reserved |

The fractional bits, multiplier and shift are ignored when the encoding does not use them.

**Illegal commands.** A command is illegal when any of these holds:
1. a bit of `cmd_payload_i` above 511 is 1;
2. the kind or version is not 1, a reserved bit is 1, the encoding is above 4, the fractional
   bits are above 31, or a transpose bit is 1;
3. K is 0, or M or N is 0 or above `Rows` or `Cols`;
4. a base address in use is not a multiple of `DataW/8` (A and B always; C when
   `write_output` is 1; sA and sB when block-scaled);
5. INT4 is requested in a build without `Int4`, or block scaling without `Scale`;
6. `clear_acc` is 0 and no sums are kept, the kept sums are of the other kind, or M or N
   differs from the kept sums'.

Correct software never issues one. An illegal command is accepted, makes no SRAM request,
publishes no milestone and raises the sticky fault.

**A legal command** reads A, B and, when block-scaled, sA and sB; runs the array over K; and,
when `write_output` is 1, writes C in the chosen encoding. A command with `write_output` 0
keeps its sums for the next command and writes nothing. C, the layouts, the encodings and the
chaining rules are the normative I/O scheme sections listed at the top.

### 7.3 Timing

**Protocol rules.**

Command port
- **P1.** A record transfers on a rising edge where `cmd_valid_i` and `cmd_ready_o` are both 1.
  The unit samples `cmd_payload_i` only on that edge.
- **P2.** `cmd_ready_o` depends only on registers.
- **P3.** After a legal command is accepted, `cmd_ready_o` is 0 until the command finishes. It
  is 1 again no later than the first cycle in which the command's complete milestone is on
  `milestone_inc_o`.
- **P4.** After an illegal command is accepted, `fault_o` is 1 from the next cycle until reset,
  and `cmd_ready_o` is 0 for as long as `fault_o` is 1.

Milestones
- **P5.** `milestone_inc_o` is 00, 01 or 10 each cycle: the number of milestones published in
  that cycle. 11 is never driven. The scoreboard counts on the rising edge.
- **P6.** Each legal command publishes exactly three milestones, in order: inputs released,
  next contribution ready, complete. With one command at a time, next contribution ready and
  complete are published together.
- **P7.** Inputs released is published only after every read response for the command's A, B,
  sA and sB has been received.
- **P8.** Complete is counted no earlier than the commit edge of the command's last C write, so
  a read accepted after the edge that counts it sees C.

Idle
- **P9.** `idle_o` is 1 exactly when no command is running and no milestone is held or on
  `milestone_inc_o`. It depends only on registers.
- **P10.** `idle_o` is 0 from the cycle after a legal command is accepted until the cycle after
  its last milestone was on `milestone_inc_o`.

SRAM channel
- **P11.** `matrix_req_*` depend only on registers. Once `matrix_req_valid_o` is 1, it and the
  request stay unchanged until accepted (`matrix_req_valid_o` and `matrix_req_ready_i` both 1
  on a rising edge).
- **P12.** Every address is a multiple of `DataW/8`. A read asks for `DataW/8` bytes, except an
  operand's last read, which asks for the bytes left. A write covers bytes 0 to
  `size_bytes` − 1 of `matrix_req_wdata_o`. `size_bytes` is never 0.
- **P13.** The unit issues a read only when it can take the response, so it never needs read
  backpressure. It expects one `matrix_rsp_valid_i` pulse per read, in request order (AS4).
- **P14.** No write is issued while a read of the same command is outstanding.
- **P15.** `matrix_req_transpose_o` is 0 and `matrix_req_element_width_o` is 00 in every cycle.

**Cycles per command.** Generated by simulation: configuration `top_8x8_payload640_lat1`,
seed 1 (8 × 8, `AccW` 32, `BlockK` 16, `BufRows` 2, `OutDepth` 9; one-cycle reads; the
arbiter accepts every request in the cycle it is offered). Cycles are counted from the
accepting edge to the edges that count milestones 1 and 3. They come from the `CMD` lines of
`bpu_matrix_unit_tb`'s log.

| Command | K | B | Scaled | `clear_acc` / `write_output` | Inputs released | Complete |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 2048 | INT4 | yes | 1 / 1 | +1,031 | +1,062 |
| 1 | 2048 | INT8 | yes | 1 / 1 | +2,055 | +2,086 |
| 2 | 1024 | INT4 | yes | 1 / 0 | +519 | +540 |
| 3 | 1024 | INT4 | yes | 0 / 1 | +519 | +550 |
| 4 | 2048 | INT8 | no | 1 / 1 | +2,053 | +2,080 |

INT8 takes one array step per cycle and INT4 two. The next command is accepted on the edge
that counts the previous one's complete milestone. With four-cycle reads and the arbiter ready
70% of the time (`top_8x8_payload512`), each command takes 4 to 7 cycles longer.

## 8. Requirements

Command port and legality
- **R01.** The unit shall accept a record only on a rising edge where `cmd_valid_i` and
  `cmd_ready_o` are both 1.
- **R02.** `cmd_ready_o` shall depend only on registers.
- **R03.** The unit shall decode bits 511:0 of `cmd_payload_i` as the version-1 record of 7.2.
- **R04.** A command with any bit of `cmd_payload_i` above 511 set shall be illegal.
- **R05.** A record with a kind or version other than 1, a reserved bit set, an encoding above
  4, fractional bits above 31, or a transpose bit set shall be illegal.
- **R06.** A command matching items 3 to 6 of the illegal-command list in 7.2 shall be illegal.
- **R07.** Record words 1 and 2 shall not affect the unit's behaviour.
- **R08.** After an illegal command is accepted, `fault_o` shall be 1 from the next cycle until
  reset.
- **R09.** While `fault_o` is 1, `cmd_ready_o` shall be 0.
- **R10.** An illegal command shall cause no SRAM request and no milestone.
- **R11.** While `fault_o` is 1, `matrix_req_valid_o` shall be 0.

Milestones and idle
- **R12.** `milestone_inc_o` shall never be 11.
- **R13.** Each accepted legal command shall publish exactly three milestones.
- **R14.** A command's inputs-released milestone shall be counted before its complete
  milestone, and only after every read response for its A, B, sA and sB.
- **R15.** A command's complete milestone shall be counted no earlier than the commit edge of
  its last C write.
- **R16.** `idle_o` shall be 1 exactly when the number of milestones counted equals three times
  the number of legal commands accepted since reset.
- **R17.** `idle_o` shall depend only on registers.
- **R18.** While `idle_o` is 1 and `fault_o` is 0, `cmd_ready_o` shall be 1.

Reset
- **R19.** While `rst_ni` is 0, `idle_o` shall be 1, `fault_o` 0, `cmd_ready_o` 1,
  `milestone_inc_o` 00 and `matrix_req_valid_o` 0.
- **R20.** A command running when reset asserts shall publish no further milestones, and the
  unit shall accept and complete a new command after reset.
- **R21.** After reset, a command with `clear_acc` 0 shall be illegal.

SRAM channel
- **R22.** `matrix_req_transpose_o` shall be 0 and `matrix_req_element_width_o` 00 in every
  cycle.
- **R23.** Every request address shall be a multiple of `DataW/8`.
- **R24.** Every read shall ask for `DataW/8` bytes, except an operand's last read, which shall
  ask for the bytes left; no request shall have `size_bytes` 0.
- **R25.** A request shall stay valid and unchanged until accepted.
- **R26.** The unit shall accept a read response in every cycle (no read backpressure).
- **R27.** The unit shall issue no write while a read of the same command is outstanding.
- **R28.** A command shall read exactly `K·Rows` bytes of A; `K·Cols` (INT8) or `⌈K·Cols/2⌉`
  (INT4) bytes of B; and, when block-scaled, `2·Rows·G` bytes of sA and `2·Cols·G` of sB,
  where G = ⌈K / `BlockK`⌉.
- **R29.** A command with `write_output` 1 shall write exactly `eb·Rows·Cols` bytes starting at
  its C address and no others, where `eb` is the encoding's byte count; a command with
  `write_output` 0 shall write nothing.

Results
- **R30.** C shall equal, bit for bit, the arithmetic of the I/O scheme ("Arithmetic", "Output
  encodings", "Memory layout"), as computed by the golden model's `matrix_v1` contract mode.
- **R31.** Elements of C outside the logical M × N shall be written as zero.
- **R32.** A chain of commands split along K shall produce the same C as one command over the
  whole K.

Parameters
- **R33.** A parameter outside its range in section 3 shall stop simulation at time 0 with
  `$fatal`.

## 9. Corner cases

- **Reset during a command.** The command is cancelled with no further milestones. C bytes
  already committed stay in SRAM, so the tile may be partly written. Read responses in flight
  are dropped by the arbiter (AS2).
- **Illegal command while the queue holds the next record.** The next record stays offered and
  is never accepted until reset (P4).
- **Inputs released and complete in the same cycle** (a short command). The unit holds the
  extra milestone and publishes it in the next cycle; `milestone_inc_o` is never 11.
- **INT4 with odd K.** The second weight of the last pair is treated as zero.
- **K not a multiple of `BlockK`.** The last scale block is short; G = ⌈K / `BlockK`⌉.
- **M or N smaller than the tile.** Lanes outside read as zero, including scales, and their
  C elements are written as zero. Layouts keep the physical strides.
- **Special scales and overflow.** A zero or subnormal scale counts as zero; an infinite or NaN
  scale makes the element NaN; an accumulator overflow saturates and gives ±infinity or the
  integer endpoint, depending on the encoding (I/O scheme, "Arithmetic").
- **The arbiter faults while a Matrix request is waiting.** If the arbiter never accepts it,
  the unit stays busy (`idle_o` 0) until reset (L3).
- **Kept sums, then reset.** The kept sums are lost; a following `clear_acc` 0 command is
  illegal (R21).

## 10. Assumptions

- **AS1.** `rst_ni` deasserts synchronously to `clk_i`.
- **AS2.** The unit is reset together with the command queues, the Matrix progress counter and
  the arbiter, and at reset the arbiter cancels writes that have not reached their commit edge
  and drops read responses in flight.
- **AS3.** The arbiter commits a Matrix write accepted on edge n by edge n + 1, visibly to any
  later read.
- **AS4.** The arbiter returns Matrix read responses in request order, at least one cycle after
  acceptance, one per read, and sends no response for a write.
- **AS5.** From acceptance until inputs released is counted, nothing writes the command's A, B,
  sA or sB in SRAM. From acceptance until complete is counted, nothing else reads or writes its
  C bytes.
- **AS6.** Operands follow the I/O scheme's memory layout.
- **AS7.** The controller sets Matrix wait targets as `3j + 1` and `3j + 3`, counting every
  legal Matrix command since reset, modulo 2^`CounterWidth`.
- **AS8.** The system's queue payload is 512 bits, or wider with zero high bits in Matrix
  records.
- **AS9.** `DataW`, `SizeW` and the address width match the arbiter's: 4096, 10 and 32.

## 11. Known limitations

- **L1.** One command at a time (`CmdDepth` = 1). A command's reads do not overlap the previous
  command's write-back.
- **L2.** No transposed operands; a transpose bit makes the command illegal.
- **L3.** If the arbiter faults and never accepts a pending Matrix request, the unit stays busy
  until reset.
- **L4.** Parameter range checks run only in simulation.
- **L5.** Unscaled sums wrap at `AccW` bits once K ≥ 2^(`AccW` − 15).
- **L6.** A command interrupted by reset can leave C partly written.
- **L7.** The output converter's 48 × 32 multiply is the unit's longest path: about 9.4 ns
  pre-layout in sky130 (local Yosys, an estimate), against 5.25 ns for the scaled array. No
  clock target is set.
- **L8.** Integration with the real arbiter is tested only outside the regression, because
  rtl #35 is not merged. No controller or Memory unit RTL exists yet to integrate with.

## 12. Open questions

| # | Question | Owner |
| --- | --- | --- |
| Q1 | Will the arbiter and the SRAM behind it guarantee AS3 (a write visible by the next edge)? #35's model does, but its I/O scheme does not say so. | Armaan, Zeb |
| Q2 | The block-scaled numerics, the output encodings and the record are defined in #32 (not merged) as well as here and in the I/O scheme. Once #32 merges, which document owns them: Zeb's `matrix_unit_spec.md`, or this spec with the I/O scheme? | Adam, Zeb |
| Q3 | Should the unit fault when the arbiter faults, instead of waiting for reset (L3)? | Zeb |
| Q4 | Is overlapped execution (`CmdDepth` = 4) wanted for this version? | Zeb, Adam |
| Q5 | What are the ASIC and FPGA clock targets (L7)? | Team |

## 13. Revision history

| Version | Date | RTL commit | Change |
| --- | --- | --- | --- |
| 0.9 | 2026-11-21 | `769219b` | First version in the block-spec template, from the integration contract. |
| 1.0 | 2026-11-22 | `769219b` | Reviewed and approved by Adam Shebani. Open questions Q1 to Q5 stay open; L3 accepted for this version. |
