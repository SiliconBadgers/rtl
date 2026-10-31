# Matrix unit interfaces

This document proposes the Matrix interfaces. The corresponding RTL and
verification changes are outside this specification PR.

The proposed `bpu_sa_sram_wrapper` computes a physical `Rows × Cols` output tile from SRAM,
with command-selected logical M/N masks and reduction length K. The default
physical tile is 8 × 8. The [specification](matrix_unit_spec.md) defines operand
layout, arithmetic, output conversion, and command lifetime.

| Module | Responsibility |
| --- | --- |
| `bpu_sa_sram_wrapper` | Commands, edge masks, SRAM buffering, array feed, conversion, output packing, and ordered progress. |
| `bpu_sa_array` | Input skew, block controls and scales, and completed-row drain. |
| `bpu_sa_pe` | One output element's integer or block-scaled accumulators. |
| `bpu_sa_output_convert` | INT32 fixed-point, FP32, FP16, or symmetric INT8 output conversion. |
| `bpu_sa_command_decoder` | Decode the provisional version-1 Matrix record. |

All ports use `clk_i`. `rst_ni` asserts asynchronously and must deassert
synchronously. Integration must cancel pending work and discard pre-reset SRAM responses
before command acceptance resumes.

## Commands and masks

A command transfers on `cmd_valid_i && cmd_ready_o`. The producer asserts valid
without waiting for ready and holds all fields until acceptance. Commands provide
A/B/C and scale-table addresses, M/N/K, INT4/scaled selection, accumulator
controls, and output conversion fields.

`1 ≤ M ≤ Rows` and `1 ≤ N ≤ Cols` select active lanes. Input streams retain their
physical Rows/Cols strides; software need not initialize inactive lane bytes.
The unit sets inactive operands and scales to zero and forces inactive output
elements to zero. K counts actual inputs. The last INT4 pair or scaled block is
padded internally, with no reads beyond the actual input extent.

Software tiles matrices larger than the physical array. The SRAM arbiter handles
transposes. Software also owns source dependencies and schedules streamed writes
so each requested input is ready when read.

The [command record](matrix_unit_spec.md#command-record) defines the provisional
512-bit record's word layout. The decoder forwards its typed
fields and malformed-record flag to the wrapper. Memory/Vector wait targets and
transpose flags pass to controller/SRAM integration rather than executing inside
the decoder. The record is separate from the shared command-router ABI.

## Continuations and progress

`clear_acc` starts a new context; `write_output` writes and ends it. A retained
context can receive further K contributions. Early overlap requires the same
M/N, scaling mode and weight width, with `clear_acc = 0`. A weight-width change
can continue after previous contributions settle.

`CmdDepth`, four by default, bounds in-flight command records. `busy_o` means at
least one command remains outstanding. `cmd_ready_o` also considers record space
and the offered command's compatibility during early overlap. A full record
queue stalls acceptance without losing progress events.

| Output pulse | Meaning |
| --- | --- |
| `inputs_released_o` | All reads for the command have returned. |
| `next_contribution_ready_o` | A retained stream admits a compatible next contribution before its computation completes. Writing commands publish readiness after output completion. |
| `complete_o` | The command's arithmetic and requested writes have completed. |
| `done_o` | Per-command completion; coincides with complete on success. |
| `err_o` | Local rejection, together with done and without success milestones. |

Milestones publish in command order, including commands already accepted during
early overlap. Pulses can coincide and have no ready signal. Done can pulse while
busy remains high. Independent new contexts wait for outstanding commands to
complete; they do not bypass an accepted continuation.

## SRAM requests and outputs

`matrix_req_valid_o` and its payload remain stable through backpressure.
Addresses are row-aligned byte addresses; each request accesses the first
`matrix_req_size_bytes_o` bytes of one row. The default row is 4096 bits, or
512 bytes.

Reads return in order on `matrix_rsp_valid_i`, at least one rising edge after
acceptance. Byte zero occupies `matrix_rsp_rdata_i[7:0]`. The four operand streams
reserve response-buffer space before issuing reads. Responses cannot stall; the
last request of each stream asks for exactly its remaining bytes.

With `WriteAcks = 0`, connect `matrix_wr_done_i` to the arbiter's write-completion
pulse qualified by Matrix tag. With `WriteAcks = 1`, write completions instead
share `matrix_rsp_valid_i`. Every write requires exactly one completion. Final
completion waits for SRAM visibility.

Output encodings are 0: legacy INT32/FP32, 1: INT32 fixed point, 2: FP32,
3: FP16, and 4: symmetric INT8. INT32 fraction and INT8 multiplier/shift fields
select integer conversion. See the [numeric contract](matrix_unit_spec.md#output-representations)
for rounding, saturation, and exception behavior.

Output elements are little-endian and contiguous in physical tile row order.
An output command writes exactly `Rows × Cols × element_bytes`, including zero
inactive lanes. FP16 uses two bytes per element and INT8 one; no 32-bit padding
is inserted. Bytes beyond that extent remain unchanged.

## Array streaming boundary

`bpu_sa_array` accepts one k-step on `in_valid_i && in_ready_o`, with one A lane
per output row and one B lane per output column. Lane zero occupies the least
significant bits. INT8 mode contributes one product per PE. INT4 mode contributes
two products from paired INT8 activations and packed signed INT4 weights.

`in_first_i` / `in_last_i` delimit integer accumulation or individual scale
blocks. `in_sfirst_i` / `in_slast_i` delimit scaled contexts; scale values are
consumed at block end. The wrapper keeps global arithmetic modes stable while
compatible contributions overlap.

Completed rows transfer on `out_valid_o && out_ready_i`. The array holds row
payload, index and last-row flag through output stalls. Integer or packed
fixed-point results reach the wrapper's conversion stage before write-back.

The [existing array test guide](../../tb/compute/Matrix_Unit/README.md) documents
the baseline INT8 array and PE tests. Verification of the proposed interfaces
must meet the [specification requirements](matrix_unit_spec.md#verification-requirements).
