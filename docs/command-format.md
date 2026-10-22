# Silicon Badgers top level command format

Top-level commands coordinate three ordered queues: Memory, Matrix, and Vector.
Software supplies operation parameters and cross-queue dependencies. The
sequencer dispatches eligible commands, and each queue publishes progress through
one wrapping counter. Commands use one fixed-size record per hardware
configuration, stored little-endian and rounded up to whole 32-bit words.

The Vector unit's local RISC-V processor interprets operation IDs and inline
arguments, generates memory operations, and issues the existing
[32-bit SIMD instructions](simd-isa.md). Individual SIMD instructions are not
top-level commands.

The shared [command format decisions](https://github.com/SiliconBadgers/architecture/blob/main/decisions/command-format-decisions.md)
record the selected organization. This specification defines the agreed fields
and scheduling behavior; the implementation details listed at the end still
need concrete definitions before a binary interface is frozen.

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

The first Memory milestone is tied to a physical SRAM row, whose size is fixed
by the SRAM interface. Early streaming consumption requires a row-aligned SRAM
destination and a supported writer/reader schedule. Once the first row is
committed, a non-transposed consumer can begin reading under the arbiter's
non-revocable access schedule. That schedule must keep each read behind its
corresponding committed write; no per-row readiness stalls are introduced.
Transpose consumers wait for full transfer completion.

For a transfer shorter than one SRAM row, committing the transferred bytes
satisfies the first milestone. It does not make the rest of that row valid.
Transfers outside the early-streaming conditions wait for full completion before
their destination is consumed.

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
| Memory | `2*j + 1` | First destination SRAM row committed for a load; first source SRAM row read for a store. For shorter transfers, the entire transferred SRAM portion has been written/read. |
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
advance the counter by more than one; a short transfer can advance it by two.

Software encodes read-after-write, write-after-read, and write-after-write
dependencies and buffer lifetimes. A first-row event permits the supported
streaming read, not reuse of the entire source buffer. Matrix input release
does not release an overlapping output buffer that is still being written.

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
- The fixed SRAM matrix layout, row/alignment rules, partial-row handling, and
  writer/reader timing guarantees for streaming consumption.
- Matrix packing/scaling fields, scale representations, numerical accumulation
  and requantization rules, and accumulator initialization/lifetime details.
- Vector firmware operation IDs and their inline argument schemas.
- Launch/acceptance interfaces, event retention for pipelined commands, error
  handling, reset behavior, and the exact destination-write visibility points.

These definitions belong to the implementation contract rather than implied
defaults in the current provisional command router or host descriptor.
