# SRAM arbitrator specification

This specification proposes the SRAM arbiter and banked SRAM contract.
Implementation and verification are separate work.

`sram_arbiter` selects SRAM requests from Memory,
Matrix, and Vector and routes read data to the requesting channel. This contract
defines ordinary logical row accesses using the existing
[I/O scheme](sram_arbiter_io_scheme.md) and the
[memory-unit completion timing](memory_unit_spec.md#53-sram-client-and-fixed-completion-timing).
The banked SRAM endpoint uses the diagonal layout and one-/two-cycle response
timing below. Remaining integration
decisions are listed under
[Interface decisions](#interface-decisions).

## Access geometry

| Quantity | Baseline |
| --- | --- |
| Logical SRAM capacity | 8 MiB, byte addresses `0x00000000` through `0x007fffff`. |
| Address width | 32 bits. |
| Logical row | 512 bytes, aligned to 512 bytes. |
| Row data | 4096 bits; logical byte `j` occupies bits `[8*j +: 8]`. |
| Physical organization | 32 banks of 256 KiB; each bank has 16,384 words of 16 bytes. |
| Vector channel | One channel carrying a contiguous row prefix, up to 512 bytes. |
| Matrix and Vector size fields | 10 bits each, encoding a byte count from 1 through 512. |
| Source tag | 4 bits, with the encodings below. |

The 512-byte row is the Memory interface granule. The
[I/O scheme](sram_arbiter_io_scheme.md#3-package-and-port-list) defines the client
widths and source-tag encodings. The bank interface supplies one
16-byte word per bank for each accepted access.

For ordinary accesses, let `A` be the logical byte address and
`R = A & ~511` the row base.

| Request channel | Tag | Legal address | Read result | Bytes enabled on a write |
| --- | --- | --- | --- | --- |
| Memory (`mm_*`) | `TagMm = 0` | `A = R`. | Entire row. | All 512 bytes. |
| Matrix (`matrix_*`) | `TagMatrix = 1` | `A = R`. | Entire row. | Row bytes `0` through `size_bytes - 1`. |
| Vector (`vec_*`) | `TagVector = 2` | `A = R`. | Entire row; the requested prefix contains `size_bytes` bytes. | Row bytes `0` through `size_bytes - 1`. |

Every accessed row lies wholly within logical SRAM. Matrix reads return a full
row; `matrix_req_size_bytes_i` selects the prefix written by a Matrix write.
Vector presents one aggregate request for a contiguous range starting at the row
base. `vec_req_size_bytes_i` is valid from 1 through 512 on both reads and writes.
Write byte `j` occupies row byte `j`; bytes beyond the requested prefix retain
their contents. Reads return the full row, and the requester consumes only its
requested prefix. The Vector memory controller owns distribution to registers
and physical arithmetic lanes; those lanes do not arbitrate independently.

A full 512-byte Vector read or write takes one accepted SRAM request. Smaller
requests use the same row bus and completion timing. The Vector memory controller
splits larger transfers at row boundaries before issuing requests. Unaligned
requests are rejected; the arbiter does not split or merge requests. Vector
accesses use the ordinary row view and have no transpose control.

## Bank mapping and transpose

### Storage layout

Partition each logical row into 32 cells of 16 bytes. For a logical byte address
`A`, use:

```text
q = A >> 9                 logical row, 0..16383
c = (A >> 4) & 31          cell within the row
j = A & 15                byte within the cell
bank = (q + c) mod 32
bank_word = q
bank_byte = j
```

An ordinary row access uses word `q` in every bank. Cell `c` is routed to or
from bank `(q + c) mod 32`; byte enables follow the same permutation. Thus
Memory writes and reads preserve logical byte order through the diagonal map.

### Matrix tile layout

For transpose element width `E` of 8, 16, or 32 bits, a tile contains 32 rows
and `P = 4096 / E` columns,
occupying 16 KiB. Tensor base `B` is 16-KiB aligned. For an `M` by `N` tensor,
store tiles in row-major order, with `ceil(N / P)` tiles per tile row. Element
`(m, n)` has this bit address relative to `B`:

```text
tile = floor(m / 32) * ceil(N / P) + floor(n / P)
element_bit = 8 * (16384 * tile + 512 * (m mod 32)) + E * (n mod P)
```

Each tile row occupies 512 bytes. The allocation occupies
`16384 * ceil(M / 32) * ceil(N / P)` bytes. Initialize elements outside the
logical shape to zero before publishing a partial tile for reads. Elements use
consecutive bytes, least-significant byte first. Packed INT4 weights use ordinary
raw-byte accesses in their prepared execution layout.

This is the standard layout for Matrix operands that use transpose.
It also defines their ordinary row view. Memory transfers copy the packed tile
bytes directly. Small tensors incur padding to the fixed tile dimensions.

### Transpose read

A transpose request selects a 16-byte cell column across one tile:

```text
A = T + 16*c
T mod 16384 = 0
0 <= c < 32
```

The complete tile `[T, T + 16384)` lies inside SRAM. The alignment rules are
equivalently `A[3:0] = 0` and `A[13:9] = 0`. For `Q = T >> 9`, gather cell `c`
from logical rows `Q + r`, where `r = 0..31`. Bank `b` reads:

```text
r = (b - c) mod 32
bank_word[b] = Q + r
```

These 32 cells use each bank exactly once. Reorder the gathered scalars into a
512-byte response `D`:

```text
D[E*(32*k + r) +: E] = cell_from_row[r][E*k +: E]
0 <= r < 32
0 <= k < 128/E
```

Each source column becomes one output row of 32 consecutive elements, ordered
by source row. The result is the scalar transpose of a 32-row by 16-byte panel,
with stored bit patterns preserved. Reading panels `c = 0..31` in order produces
the packed row-major transpose of the whole tile.

| Element width | Source columns in a 512-byte result | Bytes per packed source column |
| --- | --- | --- |
| 8 bits | 16 | 32 |
| 16 bits | 8 | 64 |
| 32 bits | 4 | 128 |

The column indices in this table are relative to the selected panel. Matrix
receives all 512 bytes and is the only client that issues transpose reads.

For example, a 32-bit panel at `T + 16*c` covers source columns `4*c` through
`4*c + 3`. Matrix receives those four columns, each as 32 packed 32-bit values.

Transpose is a read view. Writes use the ordinary row or prefix interface.

## Request interface

The client signal names follow the [I/O scheme port list](sram_arbiter_io_scheme.md#3-package-and-port-list).
Memory, Matrix, and Vector each have one request channel. Matrix transpose
controls and element-width fields are captured with each accepted request.

| Signal | Width | Contract |
| --- | --- | --- |
| `clk_i`, `rst_ni` | 1 each | Shared interface clock and active-low reset. |
| `*_req_valid_i`, `*_req_ready_o` | 1 per channel | Request acceptance on a rising edge with both asserted. |
| `*_req_is_write_i` | 1 per channel | One selects a write; zero selects a read. |
| `*_req_addr_i` | 32 per channel | Logical SRAM byte address. |
| `matrix_req_size_bytes_i` | 10 | Matrix write-prefix length. |
| `matrix_req_transpose_i` | 1 | Select the transpose read view. |
| `matrix_req_element_width_i` | 2 | Element-width encoding for a transpose read. |
| `vec_req_size_bytes_i` | 10 | Contiguous Vector prefix length, 1–512 on reads and writes. |
| `mm_req_wdata_i`, `matrix_req_wdata_i` | 4096 each | Row write data. |
| `vec_req_wdata_i` | 4096 | Vector write data; requested bytes start at bit zero. |
| `*_rsp_valid_o` | 1 per channel | Read-result pulse at the completion edge. |
| `mm_rsp_rdata_o` | 4096 | Returned ordinary logical row. |
| `matrix_rsp_rdata_o` | 4096 | Ordinary logical row or packed transpose result. |
| `vec_rsp_rdata_o` | 4096 | Entire ordinary logical row. |
| `fault_o` | 1 | Sticky request or SRAM-response fault; cleared by reset. |

Element-width encodings are `01 = 8`, `10 = 16`, and `11 = 32` bits; `00` is reserved.
The fields affect transpose permutation; ordinary accesses use raw row bytes.
Memory and Vector requests always select the ordinary view.

A requester asserts valid independently of ready and holds valid and its payload
stable through acceptance. Acceptance captures the write payload and reserves
the response slot. The next request can replace that payload after the edge.

### Arbitration

Outside an active transpose reservation, select the highest-priority pending
channel in this order:

```text
Memory > Matrix > Vector
```

At most one request is accepted per cycle. The selected channel receives ready
when its complete SRAM access and required completion slot are available.
The client handshake and SRAM issue occur on the same edge. Acceptance is atomic
across the banks used by the request.

A transpose accepted on edge `n` reserves the path through its completion on
edge `n + 2`. New requests wait at edge `n + 1`; acceptance can resume on edge
`n + 2` alongside the transpose response. This keeps completions in acceptance
order and gives each accepted Memory request its fixed one-cycle completion.

Request valid and payload feed SRAM issue combinationally. SRAM ready feeds
client ready; the SRAM endpoint supplies ready independently of the issue strobes.

With an available SRAM path, a continuously asserted Memory request can transfer
one row per cycle. Matrix and Vector service depends on gaps in higher-priority
traffic. A streaming reservation must establish its own service guarantee as
specified below.

### SRAM issue

| Signal | Width | Contract |
| --- | --- | --- |
| `sram_req_ready_i` | 1 | The complete selected access can be accepted. |
| `sram_rd_req_o`, `sram_wr_req_o` | 1 each | The selected direction pulses on the acceptance edge while SRAM is ready. |
| `sram_addr_o` | 32 | Ordinary row base `R`, or transpose panel address `T + 16*c`. |
| `sram_wdata_o` | 4096 | Write data in logical row-byte order. |
| `sram_wr_be_o` | 512 | Bit `j` enables row byte `j`; zero outside a write issue. |
| `sram_tag_o` | 4 | Selected source tag. |
| `sram_transpose_o` | 1 | Select ordinary row access or the transpose read view. |
| `sram_element_width_o` | 2 | Captured transpose element width; zero for ordinary accesses. |

Memory writes enable every byte. Matrix writes enable the prefix selected by
`matrix_req_size_bytes_i`. Vector writes enable the prefix selected by
`vec_req_size_bytes_i`.
Disabled bytes retain their stored values.

## Completion and visibility

An ordinary request accepted on rising edge `n` completes on rising edge
`n + 1`. A transpose read completes on edge `n + 2`, using one stage for the
bank read and a second for scalar permutation and result registration. Read
data is valid for capture at its completion edge. An ordinary write has committed
and is visible to subsequent reads by edge `n + 1`. Arbitration affects
acceptance time; the accepted operation's completion edge is fixed.

| SRAM response signal | Width | Contract |
| --- | --- | --- |
| `sram_rsp_valid_i` | 1 | Completion on the edge reserved by the accepted access mode. |
| `sram_rsp_tag_i` | 4 | Source tag captured with that request. |
| `sram_rsp_is_write_i` | 1 | Direction captured with that request. |
| `sram_rdata_i` | 4096 | Logical row bytes or the scalar-permuted transpose result. |

The arbiter routes each read to the channel identified by the returned tag and
pulses that channel's `*_rsp_valid_o` for capture on the same completion edge.
Vector receives the entire `sram_rdata_i` row. Read recipients capture
every result pulse; capacity for that result is part of issuing a request.

Tags identify sources. Requests from a source match their completions in
acceptance order. Back-to-back requests can use the same tag, with each response
occupying its reserved cycle. A completion and the next request's acceptance can
share an edge.

### Faults

The selected pending request faults on an address outside the 8 MiB capacity,
invalid ordinary or transpose alignment, Matrix or Vector size outside 1–512,
a transpose write, or reserved
transpose element-width code `00`. Validation
applies when a channel is selected. A malformed selected request is withheld
from SRAM and raises `fault_o` on the next rising edge.

Each accepted request reserves its mode-specific SRAM response edge. An early,
missing, unexpected, mistagged, or wrong-direction response blocks new acceptance and
raises `fault_o` on that edge. Read data is routed after the expected source
and direction match. A preceding valid read still completes alongside a malformed
new request. A write reaching its commit edge retains its effects even if its
response fails validation.

While `fault_o` is high, ready, SRAM issue, write enables, and read-result valid
outputs remain zero. Recovery uses the coordinated reset below.

For example, if a row write is accepted at edge `n` and a read of that row is
accepted at edge `n + 1`, the read result captured at edge `n + 2` contains the
written bytes, with disabled bytes preserved.

## Reset

`rst_ni` asserts asynchronously and releases synchronously to `clk_i`. During
reset, request-ready outputs, SRAM request strobes, write enables, and
read-result valid outputs are zero.

Reset clears fault and pending completion state together with the corresponding
SRAM response pipeline and client tracking. The SRAM endpoint cancels accepted
operations still awaiting their completion edge, including writes. Committed
SRAM bytes retain their values. Request acceptance resumes after that coordinated
reset boundary, so source tags refer to the new sequence of accepted accesses.

## Interface decisions

| Decision | Definition required |
| --- | --- |
| FPGA memory mapping | Map the generic 128-bit banks and byte write enables to target storage primitives and close timing for the one-/two-cycle contracts. Future Vector widths require matching changes to the shared package and access rules. |
| Early-streaming reservation | Define admission, start event, row cadence, writer/reader slots, and reservation lifetime for the [guaranteed row schedule](https://github.com/SiliconBadgers/rtl/blob/182e7f8365ae1a2936242e59436f89bb31eed6b0/docs/command-format.md#transfer-command). Every scheduled read follows its row's committed write. The guarantee must cover row-data availability through HBM response gaps as well as SRAM port allocation, and remains effective under competing requests. Transpose consumption begins after full transfer completion. |
| Completion notifications | Reconcile the sketch's per-access `sb_rd_done_o` / `sb_wr_done_o` and source tags with the current queue-milestone interface. Define any retained access-event outputs and their consumers using the visibility points above. |

## Design references

- [Compute meeting, October 10](https://app.notion.com/p/3f538826be1b81e1a8e0d468ad655828): request fields, priority and tags, transpose reads, and transfer-width discussion at 24:13–36:20.
- [Compute meeting, October 17](https://app.notion.com/p/3fd38826be1b81a2a0cbd0eb0fce8414): row chunking, byte enables, and completion matching at 0:42.
- [Command format](https://github.com/SiliconBadgers/rtl/blob/182e7f8365ae1a2936242e59436f89bb31eed6b0/docs/command-format.md): logical SRAM addressing, transpose, streaming, and queue milestones.
