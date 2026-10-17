--- a/docs/memory/sram_arbiter_io_scheme.md
+++ b/docs/memory/sram_arbiter_io_scheme.md
@@ -33,11 +33,11 @@
 
   MAT_IF["▶ <b>matrix_req_valid_i</b><br/>◀ <b>matrix_req_ready_o</b><br/>▶ <b>matrix_req_is_write_i</b><br/>▶ <b>matrix_req_size_bytes_i[9:0]</b><br/>▶ matrix_req_addr_i[31:0]<br/>▶ matrix_req_wdata_i[4095:0]<br/>◀ <b>matrix_rsp_valid_o</b><br/>◀ matrix_rsp_rdata_o[4095:0]"]:::intf
   VEC_IF["▶ <b>vec_req_valid_i[3:0]</b><br/>◀ <b>vec_req_ready_o[3:0]</b><br/>▶ <b>vec_req_is_write_i[3:0]</b><br/>▶ <b>vec_req_transpose_i</b><br/>▶ vec_req_addr_i[3:0][31:0]<br/>▶ vec_req_wdata_i[3:0][1023:0]<br/>◀ <b>vec_rsp_valid_o[3:0]</b><br/>◀ vec_rsp_rdata_o[3:0][1023:0]"]:::intf
-  MM_IF["▶ <b>mm_req_valid_i</b><br/>◀ <b>mm_req_ready_o</b><br/>▶ <b>mm_req_is_write_i</b><br/>▶ <b>mm_req_burst_len_i[8:0]</b><br/>▶ mm_req_addr_i[31:0]<br/>▶ mm_req_wdata_i[4095:0]<br/>◀ <b>mm_rsp_valid_o</b><br/>◀ mm_rsp_rdata_o[4095:0]"]:::intf
+  MM_IF["▶ <b>mm_req_valid_i</b><br/>◀ <b>mm_req_ready_o</b><br/>▶ <b>mm_req_is_write_i</b><br/>▶ mm_req_addr_i[31:0]<br/>▶ mm_req_wdata_i[4095:0]<br/>◀ <b>mm_rsp_valid_o</b><br/>◀ mm_rsp_rdata_o[4095:0]"]:::intf
 
   ARB["<b>u_sram_arbiter</b><br/>sram_arbiter.sv<br/><br/>Block 1 u_priority_arb<br/>Block 2 u_req_mux<br/>Block 3 u_addr_decode<br/>Block 4 u_bank_conflict<br/>Block 5 u_port_ctrl<br/>Block 6 u_rsp_route"]:::arb
 
-  SRAM_IF["◀ <b>sram_rd_req_o</b><br/>◀ <b>sram_wr_req_o</b><br/>▶ <b>sram_req_ready_i</b><br/>◀ <b>sram_tag_o[3:0]</b><br/>◀ <b>sram_transpose_o</b><br/>◀ <b>sram_wr_be_o[63:0]</b><br/>◀ sram_addr_o[31:0]<br/>◀ sram_wdata_o[4095:0]<br/>▶ <b>sram_rsp_valid_i</b><br/>▶ <b>sram_rsp_tag_i[3:0]</b><br/>▶ <b>sram_rsp_is_write_i</b><br/>▶ sram_rdata_i[4095:0]"]:::intf
+  SRAM_IF["◀ <b>sram_rd_req_o</b><br/>◀ <b>sram_wr_req_o</b><br/>▶ <b>sram_req_ready_i</b><br/>◀ <b>sram_tag_o[3:0]</b><br/>◀ <b>sram_transpose_o</b><br/>◀ <b>sram_wr_be_o[511:0]</b><br/>◀ sram_addr_o[31:0]<br/>◀ sram_wdata_o[4095:0]<br/>▶ <b>sram_rsp_valid_i</b><br/>▶ <b>sram_rsp_tag_i[3:0]</b><br/>▶ <b>sram_rsp_is_write_i</b><br/>▶ sram_rdata_i[4095:0]"]:::intf
   SB_IF["◀ <b>sb_rd_done_o</b><br/>◀ <b>sb_rd_tag_o[3:0]</b><br/>◀ <b>sb_wr_done_o</b><br/>◀ <b>sb_wr_tag_o[3:0]</b>"]:::intf
 
   MAT --- MAT_IF --- ARB
@@ -58,7 +58,7 @@
   classDef blk fill:#FFFFFF,stroke:#6A1B9A,stroke-width:2px,color:#4A148C
   classDef changed fill:#FFF3E0,stroke:#6A1B9A,stroke-width:2px,color:#4A148C
 
-  REQ_IN["Engine request ports (in)<br/>*_req_valid_i, *_req_is_write_i<br/>vec_req_transpose_i<br/>matrix_req_size_bytes_i, mm_req_burst_len_i<br/>*_req_addr_i, *_req_wdata_i"]:::port
+  REQ_IN["Engine request ports (in)<br/>*_req_valid_i, *_req_is_write_i<br/>vec_req_transpose_i<br/>matrix_req_size_bytes_i<br/>*_req_addr_i, *_req_wdata_i"]:::port
   RDY_OUT["Engine ready (out)<br/>matrix_req_ready_o<br/>vec_req_ready_o[3:0]<br/>mm_req_ready_o"]:::port
   RSP_OUT["Engine response ports (out)<br/>*_rsp_valid_o, *_rsp_rdata_o"]:::port
   SB_OUT["Scoreboard ports (out)<br/>sb_rd_done_o, sb_rd_tag_o[3:0]<br/>sb_wr_done_o, sb_wr_tag_o[3:0]"]:::sbport
@@ -70,18 +70,18 @@
     B2["Block 2: u_req_mux<br/>sram_arb_req_mux<br/>winner payload → unified_req<br/>tag = grant_idx"]:::blk
     B3["Block 3: u_addr_decode<br/>sram_arb_addr_decode<br/>bank_id, bank_offset,<br/>lane_mask, path enables"]:::blk
     B4["Block 4: u_bank_conflict<br/>sram_arb_bank_conflict<br/>same bank, same cycle?"]:::blk
-    B5["Block 5: u_port_ctrl<br/>sram_arb_port_ctrl<br/>can_proceed = grant_valid<br/>& ~conflict & sram_req_ready_i"]:::changed
+    B5["Block 5: u_port_ctrl<br/>sram_arb_port_ctrl<br/>can_proceed = grant_valid<br/>& ~conflict & sram_req_ready_i<br/>sram_wr_be_o from lane_mask, size_bytes"]:::changed
     B6["Block 6: u_rsp_route<br/>sram_arb_rsp_route<br/>decode sram_rsp_tag_i →<br/>engine / lane slice + scoreboard"]:::changed
   end
 
   REQ_IN -->|"*_req_valid_i"| B1
-  REQ_IN -.->|"addr, wdata, is_write,<br/>size_bytes, burst_len, transpose"| B2
+  REQ_IN -.->|"addr, wdata, is_write,<br/>size_bytes, transpose"| B2
   B1 -->|"grant_mm, grant_matrix,<br/>grant_vec[3:0], grant_idx"| B2
   B1 -->|"grant_valid, grant_mm,<br/>grant_matrix, grant_vec[3:0]"| B5
   B2 -.->|"unified_req<br/>(.addr, .is_write)"| B3
   B2 -.->|"unified_req (.wdata, .tag,<br/>.is_write, .transpose)"| B5
   B3 -->|"bank_id, lane_mask"| B4
-  B3 -->|"read_path_en, write_path_en,<br/>bank_offset, lane_mask"| B5
+  B3 -->|"read_path_en, write_path_en,<br/>bank_offset, lane_mask, size_bytes"| B5
   B4 -->|"conflict, stall_cycles_q"| B5
   B5 -->|"*_req_ready_o =<br/>can_proceed & grant_*"| RDY_OUT
   B5 -->|"sram_rd_req_o, sram_wr_req_o,<br/>sram_tag_o, sram_transpose_o,<br/>sram_wr_be_o"| SRAM_REQ
@@ -89,7 +89,7 @@
   SRAM_REQ -->|"sram_req_ready_i"| B5
   SRAM_RSP -->|"sram_rsp_valid_i, sram_rsp_tag_i,<br/>sram_rsp_is_write_i"| B6
   SRAM_RSP -.->|"sram_rdata_i[4095:0]"| B6
-  B6 -->|"*_rsp_valid_o (1-cycle pulse)"| RSP_OUT
+  B6 -->|"*_rsp_valid_o (1-cycle pulse, reads only)"| RSP_OUT
   B6 -.->|"*_rsp_rdata_o"| RSP_OUT
   B6 -->|"sb_*_done_o,<br/>sb_*_tag_o = sram_rsp_tag_i"| SB_OUT
 ```
@@ -109,9 +109,10 @@
   localparam int unsigned DATA_WIDTH      = 4096;  // 512 B SRAM row
   localparam int unsigned LANE_DATA_WIDTH = 1024;  // 128 B per Vector lane
   localparam int unsigned TAG_WIDTH       = 4;
-  localparam int unsigned SIZE_WIDTH      = 10;
-  localparam int unsigned BURST_LEN_WIDTH = 9;
-  localparam int unsigned WR_BE_WIDTH     = 64;    // width under review
+  localparam int unsigned SIZE_WIDTH      = 10;    // 1..512 bytes
+  localparam int unsigned ROW_BYTES       = DATA_WIDTH / 8;       // 512
+  localparam int unsigned LANE_BYTES      = LANE_DATA_WIDTH / 8;  // 128
+  localparam int unsigned WR_BE_WIDTH     = ROW_BYTES;            // one enable per byte
 
   // Interface-visible encoding, so values are explicit.
   typedef enum logic [TAG_WIDTH-1:0] {
@@ -123,11 +124,13 @@
     TagVec3   = 4'd5
   } req_tag_e;
 
+  // One 512 B row access. A Memory Manager burst is a sequence of these,
+  // one per handshake; the arbiter keeps no burst state (section 4.1).
   typedef struct packed {
-    logic [ADDR_WIDTH-1:0] addr;
-    logic [DATA_WIDTH-1:0] wdata;
+    logic [ADDR_WIDTH-1:0] addr;        // byte address, row aligned after Block 2
+    logic [DATA_WIDTH-1:0] wdata;       // Vector data placed in its lane slice
     logic                  is_write;
-    logic [SIZE_WIDTH-1:0] size_bytes;
+    logic [SIZE_WIDTH-1:0] size_bytes;  // 512 for MM, 128 for Vector, 1..512 for Matrix
     logic                  transpose;
     req_tag_e              tag;
   } mem_req_t;
@@ -168,7 +171,6 @@
   input  logic                                      mm_req_valid_i,
   output logic                                      mm_req_ready_o,
   input  logic                                      mm_req_is_write_i,
-  input  logic [BURST_LEN_WIDTH-1:0]                mm_req_burst_len_i,
   input  logic [ADDR_WIDTH-1:0]                     mm_req_addr_i,
   input  logic [DATA_WIDTH-1:0]                     mm_req_wdata_i,
   output logic                                      mm_rsp_valid_o,
@@ -204,13 +206,92 @@
 | --- | --- |
 | Clock / reset | Single domain `clk_i`. `rst_ni` is asserted asynchronously and must be deasserted synchronously to `clk_i` (upstream reset synchroniser). |
 | Request channels | Ready/valid. A transfer happens on the rising `clk_i` edge when `*_req_valid_i` and `*_req_ready_o` are both 1. The engine must hold valid and payload stable while stalled and must not wait for ready before asserting valid. |
-| Response channels | `*_rsp_valid_o` is a one-cycle pulse with no backpressure; the engine must capture `*_rsp_rdata_o` in that cycle. |
+| Response channels | `*_rsp_valid_o` pulses for one cycle per completed **read** only; writes do not pulse it. No backpressure: the engine must capture `*_rsp_rdata_o` in that cycle. |
 | Scoreboard channel | `sb_*_done_o` are one-cycle pulses with no backpressure; the scoreboard must accept every cycle. |
 | SRAM request | Issued only when `sram_req_ready_i` = 1. Exactly one of `sram_rd_req_o` / `sram_wr_req_o` per accepted request. |
 | SRAM response | The SRAM returns `sram_rsp_valid_i` with the same tag for reads and writes, plus `sram_rsp_is_write_i` so completions are labelled correctly. Latency is fixed by the SRAM pipeline. |
-| Units | Addresses are byte addresses. `matrix_req_size_bytes_i` is in bytes; `mm_req_burst_len_i` counts 512 B beats. |
+| Units | Addresses are byte addresses. `matrix_req_size_bytes_i` is in bytes (1–512). Every request is at most one 512 B row. |
 | Reset / quiesce | Proposed: on reset all in-flight SRAM responses are discarded and the scoreboard is reset in the same domain. To be confirmed. |
 
+### 4.1 Write enables, size and alignment
+
+`sram_wr_be_o` has one enable per byte of the 512 B row (`WR_BE_WIDTH = DATA_WIDTH / 8 = 512`).
+Bit `j` enables byte `j` of the row, which is `sram_wdata_o[8*j +: 8]`. The enables are 0 when
+`sram_wr_req_o` is 0.
+
+| Requester | Address rule | Bytes accessed | `sram_wr_be_o` on a write |
+| --- | --- | --- | --- |
+| Memory Manager | Row aligned: `mm_req_addr_i[8:0] == 0` | Whole 512 B row | All 512 bits set |
+| Matrix | Row aligned: `matrix_req_addr_i[8:0] == 0`; `matrix_req_size_bytes_i` in 1–512 | Bytes `0` to `size_bytes - 1` of the row | Bits `[size_bytes-1:0]` set |
+| Vector lane `i` | 128 B aligned with `vec_req_addr_i[i][8:7] == i` (fixed lane-to-bank wiring) | Bytes `128*i` to `128*i + 127` of the row | Bits `[128*i +: 128]` set |
+
+Reads always return the whole row; Block 6 gives each Vector lane only its 128 B slice. Block 2
+places `vec_req_wdata_i[i]` into `unified_req.wdata[1024*i +: 1024]`.
+
+Illegal inputs are defined, not undefined. Block 2 ignores `addr[8:0]` for Matrix and Memory
+Manager requests and uses the lane index instead of `addr[8:7]` for Vector requests, so a
+misaligned request accesses the aligned row or slice. A Matrix `size_bytes` of 0 is treated as a
+read or write of no bytes (all enables 0). Labelled assertions report each violation in
+simulation.
+
+### 4.2 Memory Manager bursts
+
+The Memory Manager owns its bursts. The arbiter sees only single 512 B beats and keeps no burst
+state, so there is no burst-length port.
+
+- Each beat is a separately handshaken request on `mm_req_*` with its own address and
+  `mm_req_wdata_i`. The Memory Manager advances the address by 512 per beat and supplies the next
+  write-data beat on the next request.
+- `mm_req_valid_i` may stay high across beats. The Memory Manager has top priority, so
+  back-to-back beats are accepted every cycle unless `sram_req_ready_i` or a bank conflict stalls
+  them.
+- Completion is per beat: each read beat returns one `mm_rsp_valid_o` pulse, and each beat (read
+  or write) returns one `sb_rd_done_o` or `sb_wr_done_o` pulse with tag `TagMm`. The Memory
+  Manager and scoreboard count beats to know when a burst is complete.
+
+```mermaid
+sequenceDiagram
+  participant MM as Memory Manager
+  participant ARB as sram_arbiter
+  participant SB as Scoreboard
+  Note over MM: burst of N beats starting at A
+  loop k = 0 .. N-1
+    MM->>ARB: mm_req_valid_i, addr = A + 512*k, wdata = beat k
+    ARB->>MM: mm_req_ready_o (beat k accepted)
+  end
+  ARB->>SB: sb_wr_done_o / sb_rd_done_o with TagMm, once per beat, in beat order
+  ARB->>MM: mm_rsp_valid_o once per read beat, in beat order
+```
+
+### 4.3 Outstanding requests and response ordering
+
+- The arbiter accepts at most one request per cycle and forwards it to the SRAM in acceptance
+  order. The SRAM is in order with fixed latency, so responses and completions return in the same
+  order the requests were accepted.
+- Tags 0–5 identify the source, not the request. A source may have several requests outstanding
+  under the same tag; it and the scoreboard match completions to requests by order. The
+  `n`-th `*_rsp_valid_o` (or `sb_*_done_o` with that tag) belongs to the `n`-th accepted request
+  of that kind from that source.
+- Because responses have no backpressure, a source must not have more reads outstanding than it
+  can absorb. The arbiter does not limit outstanding requests.
+- `*_rsp_valid_o` pulses for reads only. Write completion is reported only on `sb_wr_done_o`.
+- A write's data is captured when the request is accepted, so the engine may reuse its source
+  register or buffer right after the `valid && ready` handshake.
+
+### 4.4 Scoreboard ownership
+
+- The scoreboard owns all dependency tracking (RAW, WAR and WAW, across all sources). The arbiter
+  does no hazard checking. It only resolves structural bank conflicts and may reorder pending
+  requests from different sources by priority.
+- The scoreboard holds a dependent command, by not dispatching it to its engine, until every SRAM
+  access it depends on has completed. It must rely on `sb_*_done_o` pulses, not on arbitration or
+  issue order.
+- A write is complete, and its data visible to any later read, when `sb_wr_done_o` fires for it.
+  Only then may a dependent read be dispatched (RAW).
+- A read is complete when `sb_rd_done_o` fires for it. Only then may a later write to the same
+  location be dispatched (WAR), and only then may the scoreboard release that SRAM region for
+  reuse.
+
 ## 5. Request and response steps
 
 ```mermaid
@@ -231,7 +312,7 @@
   B35->>S: sram_rd_req_o / sram_wr_req_o, sram_tag_o
   Note over S: request and tag in SRAM pipeline,<br/>Block 1 already grants the next requester
   S->>B6: sram_rsp_valid_i, sram_rsp_tag_i, sram_rsp_is_write_i, sram_rdata_i
-  B6->>E: *_rsp_valid_o pulse, *_rsp_rdata_o
+  B6->>E: *_rsp_valid_o pulse, *_rsp_rdata_o (reads only)
   B6->>SB: sb_rd_done_o / sb_wr_done_o, sb_*_tag_o
 ```
 
@@ -243,7 +324,7 @@
 | `*_req_is_write_i` | control | Direction: 1 = write, 0 = read. Later selects `sram_wr_req_o` vs `sram_rd_req_o`. |
 | `*_req_addr_i[31:0]` | data | Where in SRAM. |
 | `*_req_wdata_i` | data | Write data (ignored on reads). |
-| `matrix_req_size_bytes_i` / `mm_req_burst_len_i` | control | How much to move. |
+| `matrix_req_size_bytes_i` | control | Matrix bytes to write (1–512, from the start of the row). Memory Manager and Vector sizes are fixed at 512 B and 128 B. |
 
 ### Step 2 - Decide
 
@@ -262,7 +343,7 @@
 
 | Signal | Type | What it does |
 | --- | --- | --- |
-| `unified_req` (`.addr`, `.wdata`, `.is_write`, `.size_bytes`, `.transpose`) | internal | The winner's request on one shared path (grant = mux select). |
+| `unified_req` (`.addr`, `.wdata`, `.is_write`, `.size_bytes`, `.transpose`) | internal | The winner's request on one shared path (grant = mux select). Address forced to the aligned row; Vector write data placed in its lane slice (section 4.1). |
 | `unified_req.tag` (`req_tag_e`) | control (ID) | The coat-check ticket; set from the grant and travels to the SRAM and back. |
 
 ### Step 4 - Send
@@ -280,7 +361,7 @@
 | `can_proceed` | 5 | The final GO: `grant_valid & ~conflict & sram_req_ready_i`. |
 | `sram_rd_req_o` / `sram_wr_req_o` | 5 → SRAM | Strobe to start a read or a write; only one fires, chosen by `is_write`. |
 | `sram_addr_o`, `sram_wdata_o` | 5 → SRAM | Address and write data. |
-| `sram_wr_be_o[63:0]` | 5 → SRAM | Byte enables: which bytes actually get written (only the lane's slice for a Vector write). |
+| `sram_wr_be_o[511:0]` | 5 → SRAM | One enable per byte of the 512 B row: all bytes for MM, the first `size_bytes` for Matrix, the lane's 128 B slice for Vector (section 4.1). 0 on reads. |
 | `sram_tag_o[3:0]` | 5 → SRAM | The ticket handed to the SRAM. |
 
 ### Step 5 - Wait
@@ -299,7 +380,7 @@
 | `sram_rsp_is_write_i` | control | 1 = this response completes a write; 0 = a read. |
 | `sram_rdata_i[4095:0]` | data | The 512 B of read data. Width under review. |
 | `*_rsp_rdata_o` | data → engine | Data delivered to the engine (for a Vector lane, only its 128 B slice). |
-| `*_rsp_valid_o` | control → engine | One-cycle pulse: "capture `*_rsp_rdata_o` now." Only the engine matching the tag gets it. |
+| `*_rsp_valid_o` | control → engine | One-cycle pulse on a read response: "capture `*_rsp_rdata_o` now." Only the engine matching the tag gets it. No pulse for writes. |
 
 ### Step 7 - Notify
 
@@ -307,10 +388,10 @@
 
 | Signal | Type | What it does |
 | --- | --- | --- |
-| `sb_rd_done_o` | control (strobe) | Pulse: a read finished. |
-| `sb_rd_tag_o[3:0]` | ID | Whose read finished. |
-| `sb_wr_done_o` | control (strobe) | Pulse: a write finished. |
-| `sb_wr_tag_o[3:0]` | ID | Whose write finished. |
+| `sb_rd_done_o` | control (strobe) | Pulse: a read finished; the location may now be overwritten. |
+| `sb_rd_tag_o[3:0]` | ID | Whose read finished (per-source order, section 4.3). |
+| `sb_wr_done_o` | control (strobe) | Pulse: a write finished and is visible to later reads. |
+| `sb_wr_tag_o[3:0]` | ID | Whose write finished (per-source order, section 4.3). |
 
 ## 6. Control signals grouped by job
 
@@ -323,4 +404,4 @@
 | Which part of the row | `lane_mask`, `sram_wr_be_o` |
 | Transpose | `vec_req_transpose_i` → `unified_req.transpose` → `sram_transpose_o` |
 | Whose request is this | `unified_req.tag` → `sram_tag_o` → `sram_rsp_tag_i` → `sb_*_tag_o` |
-| Notifying that data is here now | `sram_rsp_valid_i`, `*_rsp_valid_o`, `sb_*_done_o` |
+| Notifying that data is here now | `sram_rsp_valid_i`, `*_rsp_valid_o` (reads), `sb_*_done_o` (reads and writes) |
