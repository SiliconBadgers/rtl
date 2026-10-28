# Matrix unit specification

This document proposes the Matrix interface and behavior. Implementation and
verification are separate work.

The matrix unit computes `C = A × B`, with `A` of shape `M × K` and `B` of
shape `K × N`. Matrix–vector multiplication uses `N = 1`; an outer product uses
`K = 1`. Each output element stays in its processing element while contributions
along K accumulate. Successive commands can retain those accumulators and write
the completed output tile after the final contribution.

The proposed design uses output-stationary PEs and the SRAM interface described
below. The SRAM arbiter owns transpose handling. Software tiles larger matrices,
encodes source dependencies, and schedules streamed SRAM producers and consumers.
The Matrix unit masks logical edge tiles and supports the output representations
listed below. The [command draft] supplies the queue-level M, N, K and progress
model; the local [version-1 record](#command-record) gives those fields a concrete
provisional encoding.

## Commands and accumulator lifetime

`clear_acc` and `write_output` independently control the output accumulators:

| Use | `clear_acc` | `write_output` | Result |
| --- | --- | --- | --- |
| Standalone multiplication | 1 | 1 | Compute from zero and write C. |
| First K contribution | 1 | 0 | Compute from zero and retain the sums. |
| Middle K contribution | 0 | 0 | Add to the retained sums. |
| Final K contribution | 0 | 1 | Add to the retained sums and write C. |

A retained context belongs to one output tile. A continuation uses the same logical M and N and accumulator kind: integer or
block-scaled. INT8 and
INT4 weight commands can contribute to the same context. A command with
`clear_acc = 1` replaces the previous context; a successful command with
`write_output = 1` ends it. `c_base` is used only when output is written.

In the scaled profile, each command owns its scale blocks in increasing order.
A partial final block is padded with zeros inside the unit. A continuation starts
a new block: splitting an existing block between commands introduces another
rounding point, so software partitions reductions at their intended scale-block
boundaries. Every command's input and scale-table segments start at
row-aligned addresses, including segments of a continued reduction.

### Local command interface

The proposed top level is `bpu_sa_sram_wrapper`. A command transfers on
`cmd_valid_i && cmd_ready_o`; all fields are captured on that edge. `Rows × Cols`
is the physical tile, 8 × 8 by default. Commands choose logical `1 ≤ M ≤ Rows`,
`1 ≤ N ≤ Cols`, and reduction length `1 ≤ K ≤ 65,535` with the default K width.
Input lanes outside M or N are zeroed, and the final partial K pair or scale
block is zero-padded. Inactive output elements are written as zero.

| Input | Width | Meaning |
| --- | --- | --- |
| `cmd_a_addr_i`, `cmd_b_addr_i`, `cmd_c_addr_i` | `AddrW`, default 32 | A, B and C SRAM byte addresses. |
| `cmd_sa_addr_i`, `cmd_sb_addr_i` | `AddrW` | Activation and weight scale-table addresses. |
| `cmd_m_i`, `cmd_n_i` | 16 each | Active output rows and columns in the physical tile. |
| `cmd_k_i` | `KW`, default 16 | Number of actual reduction elements. |
| `cmd_int4_i`, `cmd_scaled_i` | 1 each | Packed INT4 weights and block-scaled accumulation. |
| `cmd_clear_acc_i`, `cmd_write_output_i` | 1 each | Start a new context and write its result, independently. |
| `cmd_out_format_i` | 3 | Output representation from the table below. |
| `cmd_out_frac_i` | 6 | INT32 destination fractional bits, 0–31. |
| `cmd_requant_mul_i` | 32 | Unsigned INT8 requantization multiplier. |
| `cmd_requant_shift_i` | 7 | INT8 requantization right shift, 0–127. |
| `cmd_decode_error_i` | 1 | Reject a malformed record without changing SRAM or retained sums. |

`CmdDepth` bounds accepted commands whose completion has not yet published; its
default is four. After the current command consumes its inputs, a compatible
continuation can be accepted while preceding contributions still travel through
the array. Early overlap requires `clear_acc = 0` and the same M, N, scaling mode,
and weight width. A different weight width can continue the context after the
pipeline drains. New contexts wait for outstanding commands to complete.

`cmd_ready_o` therefore depends on queue space and, during early overlap, the
offered command fields. The producer asserts valid without waiting for ready and
holds its payload through a stall. `busy_o` means at least one command remains
outstanding. `done_o` can pulse while busy remains high when earlier commands
complete during a chain.

Illegal commands include zero or out-of-range dimensions, misalignment of an
address in use, an unavailable mode, an unsupported output encoding, malformed
record fields, and incompatible retained contexts. Rejection pulses `done_o` and
`err_o` without success milestones and preserves retained sums. Basic local
rejection and reset behavior remain as described here; software owns scheduling
and source dependencies.

### Command record

The proposed Matrix record is 512 bits, version 1. Word zero occupies bits
31:0 of the record; software stores each 32-bit word little-endian. Bit ranges
in the table are local to each word. All reserved bits must be zero.

| Word | Bits | Field |
| --- | --- | --- |
| 0 | 1:0 | Kind: 1 (Matrix). |
| 0 | 15:8 | Version: 1. All other word-0 bits are reserved. |
| 1 | 31:0 | Memory wait target. |
| 2 | 31:0 | Vector wait target. |
| 3–7 | 31:0 each | A, B, C, activation-scale, and weight-scale byte addresses, respectively. |
| 8 | 15:0 / 31:16 | M / N, respectively. |
| 9 | 15:0 | K. |
| 9 | 16 / 17 | Transpose A / B, respectively. |
| 9 | 18 / 19 | `clear_acc` / `write_output`, respectively. |
| 9 | 20 / 21 | INT4 weights / block-scaled accumulation, respectively. |
| 9 | 24:22 | Output format: 0 legacy, 1 INT32, 2 FP32, 3 FP16, 4 INT8. |
| 9 | 30:25 | Integer output fractional bits, 0–31. |
| 9 | 31 | Reserved. |
| 10 | 31:0 | Unsigned requantization multiplier. |
| 11 | 6:0 | Unsigned requantization right shift. All other word-11 bits are reserved. |
| 12–15 | 31:0 each | Reserved. |

The proposed `bpu_sa_command_decoder` forwards ready/valid, decodes the record
into `matrix_command_t`, and marks malformed encodings with
`cmd_decode_error_o`, connected to the wrapper's `cmd_decode_error_i`.
The controller must enforce the decoded wait targets and route transpose flags
to the arbiter; the decoder performs neither dependency tracking nor
transposition. This record is separate from the existing command-router ABI.
Integration must define how its 32-bit wait targets map to the command queues'
configurable counter width before connecting these interfaces.

## Operand storage

Activations are signed INT8. Weights are signed INT8 or two's-complement INT4.
Let `R = DataW / 8` be the SRAM row size, 512 bytes by default. Every base address
in use is aligned to R. Element and scale bytes are contiguous within each
stream; 16-bit scales and 32-bit outputs are little-endian.

Streams retain physical tile strides even when M or N is smaller:

| Data | Location |
| --- | --- |
| `A[i,k]` | Byte `a_base + k·Rows + i`. |
| INT8 `B[k,j]` | Byte `b_base + k·Cols + j`. |
| INT4 `B[k,j]` | Nibble `q = k·Cols + j`: byte `b_base + floor(q/2)`, low nibble for even q. |
| `sA[i,g]` | bf16 at `sa_base + 2·(g·Rows + i)`. |
| `sB[g,j]` | bf16 at `sb_base + 2·(g·Cols + j)`. |
| `C[i,j]` | Output element at `c_base + element_bytes·(i·Cols + j)`. |

Here `g` indexes reduction blocks and `G = ceil(K / BlockK)`. A scale applies to one
activation row or weight column over `BlockK` consecutive k positions. The
default is `BlockK = 16`. The final partial block reads only actual K elements
and uses zero for missing contributions. Scale tables contain G entries per
physical row or column. An output command writes exactly
`element_bytes·Rows·Cols` bytes, including zero-filled inactive output lanes.

## Arithmetic

### Integer accumulation

Each PE accumulates exact signed products modulo `2^AccW`, with `AccW = 32`
by default. Continued commands apply the same wrap rule to the retained sum.
For INT8 operands, `K_total < 2^(AccW − 15)` guarantees an exact signed result
for every input, where `K_total` includes all commands in the chain.

An INT8 array step contributes one product per PE. An INT4 step contributes
`A[i,k]·B[k,j] + A[i,k+1]·B[k+1,j]` to the same output element. For an odd
unscaled K, the final pair's second contribution is zero.

### Block-scaled profile

For block g, the PE first forms the exact integer dot product:

```text
z[i,j,g] = sum(A[i,k] * B[k,j]) for k in block g
t[i,j,g] = RNE(z[i,j,g] * sA[i,g] * sB[g,j] * 2^24)
if t[i,j,g] is outside the signed 48-bit range:
    acc[i,j] = the signed 48-bit limit with t's sign
else:
    acc[i,j] = saturate48(acc[i,j] + t[i,j,g])
```

`RNE` rounds to nearest with ties to even. The scale-mantissa product and its
product with z are exact; rounding occurs when the block contribution enters
the fixed-point representation. An overflowing contribution replaces the retained
value with its signed limit. The accumulator is signed 48-bit fixed point with
24 fractional bits (Q23.24), representing values from `−2^23` through
`2^23 − 2^−24`. Blocks enter
the accumulator in increasing g order. A clear starts both the value and its
exception flags from zero.

On output, `acc / 2^24` converts to binary32 with nearest-even rounding.

| Condition | Profile behavior |
| --- | --- |
| Scale exponent is zero | Treat that scale as zero, including subnormals. |
| Scale exponent is 255 | Set the output element's sticky NaN flag. |
| Contribution or accumulator overflows | Saturate to the signed 48-bit limit and set a sticky overflow flag. |
| NaN flag at output | Write canonical NaN `0x7FC00000`. |
| Overflow flag at output, with NaN clear | Write infinity with the final accumulator's sign. |
| Finite zero at output | Write positive zero. |

Each block is scaled before its contribution joins the retained sum. The version-1
input profile uses signed codes with bf16 scales and Q23.24 retained sums.
The exporter supplies that representation; native model-format decoding belongs
to the exporter rather than the Matrix datapath.

### Output representations

The internal accumulator is independent of the SRAM output representation. Let
`v` be its real value and `a` its signed native code: integer commands have
`v = a`; scaled commands have `v = a / 2^24`.

| Encoding | Format | Bytes | Conversion |
| --- | --- | --- | --- |
| 0 | Legacy | 4 | Signed INT32 for integer commands; FP32 for scaled commands. |
| 1 | INT32 fixed point | 4 | `saturate32(RNE(v · 2^cmd_out_frac))`. |
| 2 | FP32 | 4 | IEEE binary32, nearest-even. |
| 3 | FP16 | 2 | IEEE binary16, nearest-even, including subnormals. |
| 4 | Symmetric INT8 | 1 | `clamp(RNE(a · cmd_requant_mul / 2^cmd_requant_shift), -127, 127)`. |

All output elements are little-endian. FP16 and INT8 elements are packed
contiguously, with no 32-bit padding between elements. INT8 forms the full 80-bit
magnitude product before one rounding and saturation. A multiplier of one gives
power-of-two division. For scaled inputs the shift must also account for the
native code's 24 fractional bits.

Floating conversion preserves the profile's canonical NaN and signed infinity
rules. Integer conversion maps a sticky NaN to zero and sticky overflow to the
signed endpoint; finite results saturate after rounding. FP16 converts directly
from the retained code, avoiding an intermediate FP32 rounding.

The quantization reference's
[dense path](https://github.com/zebulontaylor/QwenQuantization/blob/main/colab/src/stack_gemm.py)
uses FP16 output and an activation scale derived from `absmax / 127`; this scale
is not restricted to a power of two. Software supplies an integer multiplier
and shift for an available quantization scale, or computes the dynamic scale in
the Vector path. Matrix output conversion does not calculate a full-token absmax.
The reference's FP32 block rescaling and INT64 Q24 sum differ from this unit's
bf16-scale/Q23.24 input profile; matching output types alone does not make those
arithmetic paths bit-identical.

## SRAM access and completion

The unit uses the Matrix request and response channels defined by the
[SRAM interface](../memory/sram_arbiter_io_scheme.md#4-interface-contracts).
The default request carries a 32-bit byte address, 10-bit byte count, read/write
selection and 4096-bit write data. Valid and payload stay stable through a stall.
Each request accesses the first `size_bytes` bytes of one aligned row, with
`1 ≤ size_bytes ≤ R`.

Reads request full rows followed by the exact remaining byte count for each
stream. Responses return in request order as one-cycle pulses, at least one rising edge
after request acceptance. The unit reserves
buffer space before issuing each read and captures every response pulse. It
consumes only the requested bytes of the returned row. A, B and, in scaled mode,
the two scale tables have independent read buffers.

Writes pack consecutive C rows into SRAM rows and enable exactly the output
bytes. The unit begins writing after all operand reads have returned.
Write-data storage can be reused after request acceptance; C becomes available
to dependent reads at write completion.

Each accepted successful command publishes three ordered milestones:

| Milestone | Meaning |
| --- | --- |
| `inputs_released_o` | All SRAM operand reads have returned. Source regions can be reused, subject to overlapping output writes. |
| `next_contribution_ready_o` | A retained command has consumed its stream and admits a compatible continuation while computation is in flight. A writing command publishes this after its output completes. |
| `complete_o` | This command's contributions have settled and all its requested writes have completed. `done_o` pulses with it. |

The event records retain milestones until they can publish in command order.
A later command's input-release event cannot overtake an earlier command's
completion. Milestones can share a cycle, and the controller must capture each
pulse. There is no milestone backpressure. The readiness event describes a
compatible continuation opportunity; an incompatible offered command can still
have `cmd_ready_o = 0`.

Completions are per command. During an overlapping chain, an earlier completion
does not cancel or bypass commands already accepted behind it. An independent
new context can launch when those outstanding commands have completed. A chain's
final writing command waits for SRAM visibility before releasing subsequent work.

With default `WriteAcks = 0`, `matrix_wr_done_i` carries `sb_wr_done_o` qualified
by `sb_wr_tag_o == TagMatrix`. Every accepted write requires exactly one
completion. `WriteAcks = 1` instead accepts write-completion pulses on
`matrix_rsp_valid_i` for an adapter with that convention. Write-data storage can
be reused at acceptance, but dependent readers wait for write completion.

Software owns source readiness, read/write dependencies, and timing guarantees
for streamed producers. The unit issues SRAM reads when its own buffers have
space; it does not wait for an additional producer-ready milestone.

## Reset

All local ports use `clk_i`. `rst_ni` can assert asynchronously and deasserts
synchronously. Reset cancels the active command and retained context, clears
request and pipeline validity, and returns command acceptance to idle.
Cancellation suppresses `done_o`. Committed C writes remain in SRAM; the
interrupted tile can contain partial output.

The reset boundary must discard outstanding pre-reset responses before command
acceptance resumes. Agreement on that shared boundary is part of integration.

## Verification requirements

Verification must compare complete output tiles with a reference for the chosen
numeric profile and cover:

- Signed extrema, both weight widths, odd unscaled K, block and SRAM-row
  boundaries, and rounding ties.
- All four accumulator-control combinations, long chains, mixed weight widths,
  invalid continuations and preservation of retained sums after rejection.
- Distinct adjacent block scales, fixed-point saturation, sticky exceptions and
  the selected output conversion.
- Stalled requests and uninterrupted read-response capture, exact transfer byte
  counts, and preservation of bytes beyond C.
- M/N masks with nonzero inactive SRAM bytes, partial scaled K blocks, packed
  output formats, direct FP16 rounding, and INT8 multiplier/shift saturation.
- Overlapping retained chains, full command-record queues, ordered milestone
  publication, and compatible acceptance before preceding completion.
- Reset during accepted work and a delayed final
  write completion that holds dependent work until C is visible.

The [existing array test guide](../../tb/compute/Matrix_Unit/README.md) documents
the baseline INT8 array and PE tests. It does not establish verification of this
proposed contract. The [prototype test guide] records the source implementation's
original test interface.

Design discussions: [October 3](https://www.notion.so/3ee38826be1b81668497e19a4ea5994f)
(formats and operations), [October 10](https://www.notion.so/3f538826be1b81e1a8e0d468ad655828)
(output-stationary accumulation), and [October 17](https://www.notion.so/3fd38826be1b81a2a0cbd0eb0fce8414)
(SRAM integration).

[compute-team decisions]: https://github.com/SiliconBadgers/architecture/blob/edc25388746d791c0d0edaf6864e7ebe3672dc78/decisions/compute-team-decisions.md
[`adam/systolic-array`]: https://github.com/SiliconBadgers/rtl/tree/f5928d0c231ea336e4d887cd6bc41292ecd088e9/rtl/compute/Matrix_Unit
[command draft]: https://github.com/SiliconBadgers/rtl/blob/182e7f8365ae1a2936242e59436f89bb31eed6b0/docs/command-format.md
[block-scaling task]: https://www.notion.so/3f538826be1b80118724cf866a8db148
[prototype test guide]: https://github.com/SiliconBadgers/rtl/blob/f5928d0c231ea336e4d887cd6bc41292ecd088e9/tb/compute/Matrix_Unit/README.md
