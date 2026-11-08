# HBM controller specification

The HBM controller accepts MU and TLC word requests and issues AXI3 bursts to
`cl_hbm`. It owns arbitration, buffering, transaction IDs, burst generation, and
response ordering. The [platform wrapper](hbm_wrapper_spec.md) owns HBM wiring,
clock generation, and startup. Controller RTL is not implemented.

## Interface

### Parameters

| Parameter | Default | Valid range | Description |
| --- | --- | --- | --- |
| NUM_HBM_PORTS | 32 | 1-32 | Number of native `cl_hbm` AXI3 ports used by the controller. |
| WIDTH_INTERFACE | 512 | Powers of 2; 256-1024 | Data width in bits for the memory-unit and top-level-control interfaces. |
| MAX_READS_IN_FLIGHT | 32 | 1-128 | Global maximum of accepted reads awaiting client response acceptance, shared by MU and TLC across all HBM ports. |
| `BYTES_INTERFACE` | 64 | Derived: `WIDTH_INTERFACE / 8` | Bytes per memory-unit or top-level-control word. |
| `ADDR_OFFSET_BITS` | 6 | Derived: `$clog2(BYTES_INTERFACE)` | Number of low byte-address bits omitted from a word address. |
| `WIDTH_MU_ADDR` | 28 | Derived: `34 - ADDR_OFFSET_BITS` | Word-address width for both client interfaces across the full HBM address space. |

### Controller ports

AXI signals are arrays indexed by `n`, from zero through `NUM_HBM_PORTS - 1`.
`nn` in a native IP port name is the two-digit index, such as `00` or `31`.
Widths are bits per element; `_i` denotes an input and `_o` an output.

| Controller port | Connection | Width | Reset value | Description |
| --- | --- | --- | --- | --- |
| `clk_i` | 450 MHz clock source | 1 | — | Controller and client-interface clock. |
| `rst_ni` | Active-low reset source | 1 | — | Controller reset. |
| `hbm_awaddr_o[n]` | `cl_hbm.AXI_nn_AWADDR` | 34 | `'0` | Write byte address. |
| `hbm_awburst_o[n]` | `cl_hbm.AXI_nn_AWBURST` | 2 | `2'b01` | Write burst type; `2'b01` encodes INCR. |
| `hbm_awid_o[n]` | `cl_hbm.AXI_nn_AWID` | 6 | `'0` | Write transaction ID. |
| `hbm_awlen_o[n]` | `cl_hbm.AXI_nn_AWLEN` | 4 | `'0` | Write burst length minus one (1–16 beats). |
| `hbm_awsize_o[n]` | `cl_hbm.AXI_nn_AWSIZE` | 3 | `3'd5` | Bytes per write beat encoded as log2; `3'd5` encodes 32 bytes. |
| `hbm_awvalid_o[n]` | `cl_hbm.AXI_nn_AWVALID` | 1 | `'0` | Write address is valid. |
| `hbm_awready_i[n]` | `cl_hbm.AXI_nn_AWREADY` | 1 | — | HBM can accept the write address. |
| `hbm_wdata_o[n]` | `cl_hbm.AXI_nn_WDATA` | 256 | `'0` | Write data. |
| `hbm_wstrb_o[n]` | `cl_hbm.AXI_nn_WSTRB` | 32 | `32'hffff_ffff` | One write enable per byte. |
| `hbm_wlast_o[n]` | `cl_hbm.AXI_nn_WLAST` | 1 | `'0` | Final beat of the write burst. |
| `hbm_wvalid_o[n]` | `cl_hbm.AXI_nn_WVALID` | 1 | `'0` | Write data is valid. |
| `hbm_wready_i[n]` | `cl_hbm.AXI_nn_WREADY` | 1 | — | HBM can accept the write data. |
| `hbm_bid_i[n]` | `cl_hbm.AXI_nn_BID` | 6 | — | Transaction ID of the write response. |
| `hbm_bresp_i[n]` | `cl_hbm.AXI_nn_BRESP` | 2 | — | Write response status. |
| `hbm_bvalid_i[n]` | `cl_hbm.AXI_nn_BVALID` | 1 | — | Write response is valid. |
| `hbm_bready_o[n]` | `cl_hbm.AXI_nn_BREADY` | 1 | `'0` | Controller can accept the write response. |
| `hbm_araddr_o[n]` | `cl_hbm.AXI_nn_ARADDR` | 34 | `'0` | Read byte address. |
| `hbm_arburst_o[n]` | `cl_hbm.AXI_nn_ARBURST` | 2 | `2'b01` | Read burst type; `2'b01` encodes INCR. |
| `hbm_arid_o[n]` | `cl_hbm.AXI_nn_ARID` | 6 | `'0` | Read transaction ID. |
| `hbm_arlen_o[n]` | `cl_hbm.AXI_nn_ARLEN` | 4 | `'0` | Read burst length minus one (1–16 beats). |
| `hbm_arsize_o[n]` | `cl_hbm.AXI_nn_ARSIZE` | 3 | `3'd5` | Bytes per read beat encoded as log2; `3'd5` encodes 32 bytes. |
| `hbm_arvalid_o[n]` | `cl_hbm.AXI_nn_ARVALID` | 1 | `'0` | Read address is valid. |
| `hbm_arready_i[n]` | `cl_hbm.AXI_nn_ARREADY` | 1 | — | HBM can accept the read address. |
| `hbm_rdata_i[n]` | `cl_hbm.AXI_nn_RDATA` | 256 | — | Read data. |
| `hbm_rid_i[n]` | `cl_hbm.AXI_nn_RID` | 6 | — | Transaction ID of the read response. |
| `hbm_rresp_i[n]` | `cl_hbm.AXI_nn_RRESP` | 2 | — | Read response status. |
| `hbm_rlast_i[n]` | `cl_hbm.AXI_nn_RLAST` | 1 | — | Final beat of the read burst. |
| `hbm_rvalid_i[n]` | `cl_hbm.AXI_nn_RVALID` | 1 | — | Read data and response are valid. |
| `hbm_rready_o[n]` | `cl_hbm.AXI_nn_RREADY` | 1 | `'0` | Controller can accept the read data and response. |
| `fatal_error_o` | Protocol-fault status | 1 | `'0` | Sticky protocol fault; cleared by `rst_ni`. |

### Client ports

Both clients use the following ports. Replace `<client>` with `mu` for the
memory unit or `tlc` for top-level control. Directions and reset values are
relative to the controller, as in the table above.

| Controller port | Connection | Width | Reset value | Description |
| --- | --- | --- | --- | --- |
| `<client>_wvalid_i` | Client | 1 | — | Write request address and data are valid. |
| `<client>_wready_o` | Client | 1 | `'0` | Controller can accept the write address and data together. |
| `<client>_waddr_i` | Client | `WIDTH_MU_ADDR` | — | Write word address. |
| `<client>_wdata_i` | Client | `WIDTH_INTERFACE` | — | Full-word write data; all bytes are written. |
| `<client>_bvalid_o` | Client | 1 | `'0` | Write completion response is valid. |
| `<client>_bready_i` | Client | 1 | — | Client can accept the write completion response. |
| `<client>_berror_o` | Client | 1 | `'0` | Write failed; meaningful when `<client>_bvalid_o` is high. |
| `<client>_arvalid_i` | Client | 1 | — | Read request address is valid. |
| `<client>_arready_o` | Client | 1 | `'0` | Controller can accept the read request address. |
| `<client>_araddr_i` | Client | `WIDTH_MU_ADDR` | — | Read word address. |
| `<client>_rvalid_o` | Client | 1 | `'0` | Read response is valid. |
| `<client>_rready_i` | Client | 1 | — | Client can accept the read response. |
| `<client>_rdata_o` | Client | `WIDTH_INTERFACE` | `'0` | Read data; meaningful when `<client>_rvalid_o` is high and `<client>_rerror_o` is low. |
| `<client>_rerror_o` | Client | 1 | `'0` | Read failed; meaningful when `<client>_rvalid_o` is high. |

### Client protocol

The memory unit and top-level control unit each have independent write-request,
write-response, read-request, and read-response channels. Each request
transfers one word. Writes include the address and data in the same handshake
and write every byte; neither client interface has byte enables. Addresses are
word indices, with each word aligned to `BYTES_INTERFACE` bytes. The controller
forms the 34-bit HBM byte address by appending `ADDR_OFFSET_BITS` zero bits to
the client address.

A channel transfers on a rising edge of `clk_i` when its valid and ready signals
are both high. The sender holds valid and the payload stable until acceptance.

## Transaction behavior

### Address mapping and data layout

The configured F2 HBM address map and global-addressing behavior are described
in the [HBM integration guide](../../tb/memory/f2_hbm/README.md#hbm-interface).
The byte address identifies the memory location through any AXI ingress port.

Each client request maps to one INCR burst of
`WIDTH_INTERFACE / 256` beats. `ARSIZE` or `AWSIZE` is `3'd5`, and `ARLEN` or
`AWLEN` is the number of beats minus one. Beat zero carries client data bits
`[255:0]`; each later beat carries the next 256 bits at the next 32-byte address.
All write strobes are asserted for these full-width beats. Word alignment keeps
each burst within a 4 KiB address region.

For the default 512-bit interface, word address `28'h1` produces a two-beat
burst at byte addresses `34'h40` and `34'h60`, with `ARLEN` or `AWLEN` equal to
one.

### Responses and memory visibility

During normal operation, each accepted request produces exactly one response
to its requesting client, including requests with HBM transaction errors.
Each client has separate read and write response sequences. Successful and
failed responses retire in request order within their sequence; retirement
occurs when the client accepts the response. Completed responses wait behind
earlier requests in the same sequence.

Software schedules dependent accesses so each write completes successfully
before a dependent read or write is submitted. This applies within each client
and across MU and TLC, including accesses that overlap a multi-beat write. The
controller relies on this scheduling when issuing requests to HBM.

### Read processing

The controller assigns each accepted read a position in its client's request
sequence and issues the burst on a selected HBM port. It matches returning beats
using the port and `RID`, assembles the response word, records errors, and
checks `RLAST` against the expected final beat.

### Write processing

Each port sends writes in its write-address transaction order and finishes each
write-data burst before beginning the next. The controller presents W data
independently of AW ready.

The controller matches each B response using the port and `BID`. A client write
completion becomes eligible after the address, all data beats, and the HBM B
response have been accepted.

## Arbitration and resources

Before accepting a read, reserve tracking resources and storage for the complete
response word and error status. Before accepting a write, reserve storage for
the address, complete data word, and completion status. Retain response storage
until client acceptance, including through client stalls. AXI read tracking
can be released after all expected beats and their status have been recorded.

`MAX_READS_IN_FLIGHT` limits accepted reads awaiting client response acceptance
across both clients and all HBM ports. Stall new reads when all slots are
occupied. Deassert client request ready whenever required resources are
unavailable, and accept HBM responses only when their data, status, and ordering
information can be retained.

TLC has priority over MU when eligible requests compete for the same HBM port
or shared resource. Sustained TLC traffic can delay MU service. Priority applies
when selecting a new request: an asserted AXI address remains selected until
accepted, and a write-data burst retains its grant through the final beat.

Reads, writes, and traffic on different HBM ports can overlap when resources
permit, including simultaneous read and write acceptance. Accepted work
progresses independently of subsequent client requests.

## Errors and reset

`clk_i` is the 450 MHz clock for all controller ports. `rst_ni` is active low
and releases synchronously to `clk_i`, after HBM initialization. The
[wrapper startup sequence](hbm_wrapper_spec.md#startup-sequence) supplies this
clock and reset. During reset, hold client request-ready, client response-valid,
AXI request-valid, `RREADY`, and `BREADY` low. After release, resource availability
controls the handshakes. The controller has no software registers.

Protocol faults, including unexpected response IDs, incorrect `RLAST`, and extra
response beats, put the controller into an error state. In this state, the
controller asserts `fatal_error_o`, stops accepting client requests, and stops
selecting new HBM transactions. Already asserted AXI valid signals and their
payloads remain stable until accepted or reset; an active write-data burst keeps
its grant. Recovery requires reset.

HBM `RRESP` or `BRESP` values other than OKAY (`2'b00`) set the corresponding
client error flag. Any failed beat marks the complete read as failed. The
controller consumes the remaining expected beats and returns one error response.

The client decides whether to retry a failed transaction. A failed write can
leave memory partially updated.

Asserting `rst_ni` low clears request tracking, buffered responses, and AXI issue
state, and clears `fatal_error_o`. Outstanding client requests are canceled
without completion responses. Clients reset their response-order tracking at the same boundary. Before reusing
locations affected by canceled writes, clients must reestablish valid contents.

After reset release, the AXI response channels must not return responses from
canceled transactions; transaction IDs can be reused for new requests.

To quiesce traffic, clients stop submitting requests and accept responses until
all outstanding work retires.

## Open decisions

| ID | Question | Owner | Answer |
| --- | --- | --- | --- |
| HBM-Q1 | How does an address select an AXI ingress port, including with fewer than 32 ports? | Unassigned | Open. |
| HBM-Q3 | What are the write and queue limits, simultaneous acceptance capability, and resource reservations between clients? | Unassigned | Open. |
| HBM-Q4 | How are six-bit AXI IDs allocated, matched, and reused? How are up to 128 reads represented without ambiguous responses on a port? | Unassigned | Open. |
