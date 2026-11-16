# Command format decisions

This proposed organization accompanies the [command format specification](command-format.md).
The records and milestone counts remain subject to review. Transfer accesses
follow the merged [SRAM arbiter contract](https://github.com/SiliconBadgers/rtl/blob/a3687fb919773fb0b9948c13a7d941315e344a64/docs/memory/sram_arbiter_io_scheme.md#4-interface-contracts).

- Command organization
  - Three top-level command kinds target three ordered queues:
    `TRANSFER` for Memory, `MATRIX` for Matrix, and `VECTOR_RUN` for Vector.
  - The two-bit kind encoding is `00 TRANSFER`, `01 MATRIX`,
    `10 VECTOR_RUN`, and `11 reserved`.
  - All commands use one fixed-size record per hardware configuration,
    stored little-endian and rounded up to whole 32-bit words.
  - Records contain the kind, two wait targets, and a kind-specific payload.
    Unused payload and record padding bits are zero.
  - Address widths, transfer-length width, counter width, dimension width,
    Vector operation-ID width, and inline argument sizing are parameterized.
    Transfer length has its own width parameter.

- Dependencies and scoreboard
  - Each queue has one wrapping progress counter, initially zero.
    Counters advance at defined milestones; software computes targets ahead
    of time from the fixed execution order.
  - Each command has one wait target for each of the other two queues.
    The command kind determines the target queues; no wait count or queue IDs
    are carried. Target zero means no wait.
  - Waits use a modular reached-or-passed comparison. Software keeps live
    dependencies within half the counter range and does not use zero as a
    real wait target. Wraparound does not require a drained reset boundary.
  - Software schedules read-after-write, write-after-read, and write-after-write
    hazards. Milestones publish in command order within each queue, including
    when command execution overlaps.

- Memory commands
  - Transfers copy contiguous raw bytes between HBM and SRAM using direction,
    HBM address, SRAM address, and byte length.
  - Commands use logical SRAM byte addresses. The SRAM interface handles
    diagonal bank mapping and defines the physical SRAM row size.
  - The compatible SRAM baseline uses a 512-byte-aligned SRAM address and a
    positive byte length that is a multiple of 512. The Memory Manager splits
    the transfer into separately handshaken full-row beats and holds each
    request stable while stalled. Every Memory Manager write enables all
    512 bytes; arbitrary partial rows require a byte preservation mechanism.
  - Each transfer advances the Memory counter twice: after the first full SRAM
    row write/read completes, then at full transfer completion. A one-row load
    can advance by two when both events coincide. First-row progress does not
    authorize early consumption or whole-buffer reuse.
  - Dependent consumers, including transposed consumers, and whole-buffer reuse
    wait for full transfer completion. SRAM write visibility and read completion
    come from scoreboard completion pulses, not request acceptance. Store
    completion also requires completed HBM destination writes.
  - Partial rows and early streaming are proposed extensions. The arbiter
    permits per-beat stalls and supplies no non-revocable writer/reader
    schedule. Streaming requires a schedule that keeps every read behind its
    completed write under HBM and SRAM stalls.
  - The remaining command-to-Memory Manager/HBM contract, including HBM
    alignment and destination-write completion, belongs to
    [issue #20](https://github.com/SiliconBadgers/rtl/issues/20).

- Matrix commands
  - One operation uses explicit `m`, `n`, and `k` for matrix multiplication,
    matrix-vector multiplication (`n=1`), and outer products (`k=1`).
  - Fields are `a_base`, `b_base`, `c_base`, `m`, `n`, `k`, `transpose_a`,
    `transpose_b`, `clear_acc`, and `write_output`.
  - Matrix uses the standard SRAM layout without arbitrary row strides.
  - `clear_acc` and `write_output` are independent controls. Successive K tiles
    retain and pipeline contributions into the same output accumulators.
  - Matrix scales block contributions before combining them and handles final
    requantization when output is written. `c_base` is ignored when output is
    retained.
  - Each Matrix command advances its counter three times, in this order:
    inputs released, next compatible operation ready, and complete.
    Input release precedes readiness for the next operation.

- Vector commands
  - `VECTOR_RUN` carries a firmware operation ID and inline arguments.
    The ID defines the operation, argument interpretation, and data formats.
  - The Vector unit's local RISC-V processor generates memory operations and
    the existing 32-bit SIMD instructions. There is no top-level
    `VECTOR_MEMORY` command, argument-block pointer, or individual SIMD word.
  - LUT access stays inside the Vector unit. Packed values are loaded as raw
    words and unpacked through SIMD programs.
  - Each Vector operation advances its counter twice: issue complete, then
    execution complete with output writes visible. Issue completion allows
    the CPU to prepare the next operation; there is no separate input-release
    milestone.

See the [command format specification](command-format.md)
for record fields and scheduling semantics.
