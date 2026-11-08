# Silicon Badgers top level command format

This proposal defines top-level commands for three ordered queues: Memory,
Matrix, and Vector.
Software supplies operation parameters and cross-queue dependencies. The
sequencer dispatches eligible commands, and each queue publishes progress through
one wrapping counter. Commands use one fixed-size record per hardware
configuration, stored little-endian and rounded up to whole 32-bit words.

The Vector unit's local RISC-V processor interprets operation IDs and inline
arguments, generates memory operations, and issues the existing
[32-bit SIMD instructions](simd-isa.md). Individual SIMD instructions are not
top-level commands.

The accompanying [command format decisions](command-format-decisions.md)
record the proposed fields, queue organization, and milestone counts. These
remain subject to review. The transfer baseline below follows the merged
[SRAM arbiter contract](https://github.com/SiliconBadgers/rtl/blob/a3687fb919773fb0b9948c13a7d941315e344a64/docs/memory/sram_arbiter_io_scheme.md#4-interface-contracts).
Partial-row transfers and early streaming require extensions to that contract.
The implementation details listed at the end still need concrete definitions
before a binary interface is frozen.

## Command record

| Field | Width | Meaning |
| --- | --- | --- |
| `kind` | 2 bits | Command kind and destination queue |
| `wait_target_0` | `CounterWidth` | Required progress of the first other queue |
| `wait_target_1` | `CounterWidth` | Required progress of the second other queue |
| `payload` | `PayloadBits` | Kind-specific fields; unused payload bits are zero |

The record has no wait count or queue IDs. The kind determines which queues the
two wait targets reference. A zero target disables that wait; both enabled waits
must be satisfied before the command can issue.

| `kind` | Command | Queue | `wait_target_0` | `wait_target_1` |
| --- | --- | --- | --- | --- |
| `00` | `TRANSFER` | Memory | Matrix counter | Vector counter |
| `01` | `MATRIX` | Matrix | Memory counter | Vector counter |
| `10` | `VECTOR_RUN` | Vector | Memory counter | Matrix counter |
| `11` | Reserved | — | — | — |

### Width parameters

| Parameter | Meaning |
| --- | --- |
| `HbmAddressWidth` | HBM byte-address width |
| `SramAddressWidth` | Logical SRAM byte-address width |
| `TransferLengthWidth` | Transfer byte-count width, independent of address widths |
| `CounterWidth` | Queue progress and wait-target width |
| `DimensionWidth` | Width of each Matrix dimension |
| `VectorOpIdWidth` | Vector firmware operation-ID width |
| `VectorArgCount` | Number of inline Vector argument slots |
| `VectorArgWidth` | Width of each inline Vector argument slot |

```text
HeaderBits   = 2 + 2 * CounterWidth
TransferBits = 1 + HbmAddressWidth + SramAddressWidth + TransferLengthWidth
MatrixBits   = 3 * SramAddressWidth + 3 * DimensionWidth + 4
VectorBits   = VectorOpIdWidth + VectorArgCount * VectorArgWidth
PayloadBits  = max(TransferBits, MatrixBits, VectorBits)
CommandBits  = 32 * ceil((HeaderBits + PayloadBits) / 32)
```

Bits added to round the record to whole words are zero. Parameter values belong
to one shared hardware/software configuration; they do not vary by command.

## Transfer command

| Field | Width | Meaning |
| --- | --- | --- |
| `direction` | 1 bit | HBM to SRAM or SRAM to HBM |
| `hbm_address` | `HbmAddressWidth` | First HBM byte |
| `sram_address` | `SramAddressWidth` | First logical SRAM byte |
| `length_bytes` | `TransferLengthWidth` | Number of contiguous bytes copied |

Transfers preserve raw bytes. They do not unpack weights, convert numerical
formats, or describe strided copies. The SRAM interface handles diagonal bank
mapping from logical addresses.

### Mapping to the current SRAM contract

The [SRAM arbiter contract](https://github.com/SiliconBadgers/rtl/blob/a3687fb919773fb0b9948c13a7d941315e344a64/docs/memory/sram_arbiter_io_scheme.md#4-interface-contracts)
defines the SRAM side of a transfer. The compatible baseline requires a
512-byte-aligned `sram_address` and a positive `length_bytes` that is a multiple
of 512. These are SRAM-side constraints; HBM alignment, legal address ranges,
and command validation remain part of the upstream integration work in
[issue #20](https://github.com/SiliconBadgers/rtl/issues/20).

The Memory Manager splits a transfer into `length_bytes / 512` full-row beats.
Beat `i` accesses `sram_address + 512*i`. Each beat has a separate ready/valid
handshake; its valid, address, direction, and write data remain stable while
stalled. All 512 byte enables are set for a Memory Manager write. SRAM readiness
and bank conflicts can stall any beat; priority does not guarantee an
uninterrupted burst. Read responses have no backpressure, so the Memory Manager
must reserve space to capture every outstanding read response.

The Memory Manager and scoreboard count per-beat completions in source order.
For a load, `sb_wr_done_o` with `TagMm` marks a row written and visible; request
acceptance alone does not. For a store, `sb_rd_done_o` with `TagMm` marks a
source row read. Store completion also requires the HBM destination writes to
complete; the SRAM read-completion pulse does not establish HBM visibility.
The HBM completion interface and its aggregation into command completion remain
to be specified in issue #20.

Dependent consumers, including transposed consumers, wait for full transfer
completion in this baseline. The scoreboard gates dependent dispatch using
completed SRAM accesses, rather than arbitration or issue order. The first-row
milestone reports progress only: it neither authorizes early consumption nor
releases the whole source buffer for reuse.

For example, a 1024-byte load to SRAM address `0x1000` writes full rows at
`0x1000` and `0x1200`. The first write completion reports first-row progress;
the second completes the SRAM writes. A dependent Matrix command waits for the
whole-transfer milestone. A store of the same range reads those two rows and
waits for both HBM destination writes before reporting whole-transfer completion.

Partial rows and early streaming are proposed extensions, unsupported by this
baseline. A 32-byte load cannot be sent as a Memory Manager write: it would
overwrite all 512 bytes, including the other 480 bytes. Waiting for completion
does not preserve those bytes. Software can instead transfer a full padded row
when it owns every byte; arbitrary partial transfers need a specified byte
preservation mechanism. Early streaming needs a schedule that keeps every read
behind its completed write under both HBM and SRAM stalls. The arbiter supplies
no non-revocable writer/reader schedule.

## Matrix command

| Field | Width | Meaning |
| --- | --- | --- |
| `a_base`, `b_base`, `c_base` | `SramAddressWidth` each | Logical SRAM byte addresses |
| `m`, `n`, `k` | `DimensionWidth` each | Logical multiplication dimensions |
| `transpose_a`, `transpose_b` | 1 bit each | Read the respective input transposed |
| `clear_acc` | 1 bit | Clear accumulators before computing this contribution |
| `write_output` | 1 bit | Requantize and write the accumulated output |

One dimension-based operation covers `C = A * B`: A is M by K, B is K by N,
and C is M by N. Matrix-vector multiplication uses `n=1`; an outer product uses
`k=1`. Dimensions are explicit in every command and bounded by the supported
hardware tile sizes. Transpose flags change storage interpretation, not these
logical shapes.

The initial layout uses the standard SRAM matrix layout rather than arbitrary
row strides. The SRAM interface performs row/column bank mapping. `c_base` is
ignored when `write_output=0`.

| Use | `clear_acc` | `write_output` |
| --- | --- | --- |
| Standalone multiplication | 1 | 1 |
| First K tile | 1 | 0 |
| Middle K tile | 0 | 0 |
| Last K tile | 0 | 1 |

The Matrix unit retains output accumulators across successive K tiles. Pipelining
targets contributions to the same output tile. Block contributions are scaled
before they are combined, and Matrix handles final requantization when output
is written. Packing and scaling controls are not allocated fields in this draft.

## Vector run command

| Field | Width | Meaning |
| --- | --- | --- |
| `operation_id` | `VectorOpIdWidth` | Firmware operation and its argument/data-format contract |
| `args[]` | `VectorArgCount * VectorArgWidth` | Inline operation-specific arguments |

Firmware defines operation IDs, argument layouts, and numerical formats. The
top-level command does not contain an argument-block pointer or a SIMD program
entry address. Arguments can contain addresses of input, output, and state data.

The local RISC-V processor generates its own memory and SIMD commands, so there
is no top-level `VECTOR_MEMORY` command. LUT access is internal to the Vector
unit. Packed data can be loaded as raw words and unpacked with SIMD programs;
top-level transfers do not expand packed INT4 values into lanes. Local memory
and SIMD execution must preserve the register and buffer dependencies established
by firmware when operations overlap.

## Queue progress and dependencies

Each queue has one `CounterWidth`-bit progress counter, initially zero. Counters
count milestones rather than commands or FIFO slots. Software computes targets
from the fixed milestone counts; no separate command or sub-event counter is
carried in a command.

Let `j` be the zero-based command ordinal within a queue from its initial state.
The following targets are taken modulo `2^CounterWidth`.

| Queue | Target | Milestone |
| --- | --- | --- |
| Memory | `2*j + 1` | First full destination SRAM row completed for a load; first full source SRAM row read completed for a store. Progress only under the current SRAM contract. |
| Memory | `2*j + 2` | Transfer complete, including destination writes |
| Matrix | `3*j + 1` | All SRAM input reads finished; input buffers released |
| Matrix | `3*j + 2` | Next compatible K-tile operation can launch |
| Matrix | `3*j + 3` | Accumulation finished and requested output writes completed |
| Vector | `2*j + 1` | All local SIMD/memory commands issued; CPU can prepare the next operation |
| Vector | `2*j + 2` | Operation finished and output writes visible |

Matrix releases its inputs before publishing readiness for the next operation.
Vector has no separate input-release milestone. Its issue-complete milestone
does not release buffers or establish output visibility.

Commands issue in queue order, but Matrix and Vector can overlap successive
commands using their early readiness milestones. Milestones publish in command
order within each queue. A later command's event cannot advance the counter past
an unpublished event of an earlier command. Simultaneous ordered milestones can
advance the counter by more than one; a one-row load can advance it by two
when its first-row and whole-transfer completions coincide.

Software encodes read-after-write, write-after-read, and write-after-write
dependencies and buffer lifetimes. Under the current SRAM contract, a dependent
consumer or whole-buffer reuse waits for the whole-transfer milestone, not the
first-row event. Matrix input release does not release an overlapping output
buffer that is still being written.

### Counter wraparound

```text
delta = (counter - target) modulo 2^CounterWidth
ready = (target == 0) OR (delta < 2^(CounterWidth - 1))
```

Each wait uses this modular reached-or-passed comparison. Software keeps live
dependencies within half the counter range so past and future targets remain
distinguishable. Counter wraparound is supported without a required drained
reset boundary.

Zero remains the no-wait sentinel when a milestone wraps to zero. Software
cannot directly wait on that milestone using zero; it must schedule the consumer
through another valid dependency or a later nonzero milestone. Exact-value
waits are not used because a delayed consumer can miss a counter value.

## Details to specify before implementation

- Concrete width parameters, bit offsets, payload field packing, and Transfer
  direction encoding.
- The fixed SRAM matrix layout and the remaining command-to-Memory Manager/HBM
  contract in issue #20, including HBM alignment and destination-write completion.
  Partial-row preservation and stall-safe streaming require explicit extensions
  to the full-row/full-completion baseline above.
- Matrix packing/scaling fields, scale representations, numerical accumulation
  and requantization rules, and accumulator initialization/lifetime details.
- Vector firmware operation IDs and their inline argument schemas.
- Launch/acceptance interfaces, event retention for pipelined commands, error
  handling, reset behavior, and the exact destination-write visibility points.

These definitions belong to the implementation contract rather than implied
defaults in the current provisional command router or host descriptor.
