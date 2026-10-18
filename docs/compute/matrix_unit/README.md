# Matrix Unit diagrams and verification plan

This folder holds the figures for the [Matrix Unit I/O scheme](../matrix_unit_io_scheme.md).
They cover the Matrix Unit only: `bpu_sa_sram_wrapper` and everything under it, plus the
`sram_arbiter` matrix port it talks to. The SVGs in [svg/](svg) are generated; regenerate them whenever a port or
parameter changes. [png/](png) holds PNG copies of the same figures, for chat and slides.

| File | Shows |
| --- | --- |
| [matrix_unit_hierarchy.svg](svg/matrix_unit_hierarchy.svg) | The module hierarchy: every instance (name, module, count), the signals between them, and the logic written inline in the wrapper, muxes included. |
| [matrix_unit_modules.svg](svg/matrix_unit_modules.svg) | One card per module (all seven `.sv` files) with its parameters and every port, parsed from the RTL headers. |
| [matrix_unit_ports.svg](svg/matrix_unit_ports.svg) | The top-level ports of `bpu_sa_sram_wrapper` and their default parameters. |
| [matrix_unit_structure.svg](svg/matrix_unit_structure.svg) | The blocks inside the wrapper, the data flow, and where each assertion lives. |
| [matrix_unit_timeline.svg](svg/matrix_unit_timeline.svg) | A schematic waveform of one block-scaled command, and the rules a checker can enforce. |
| [matrix_unit_8x8_array.svg](svg/matrix_unit_8x8_array.svg) | The 8 × 8 PE grid, its input delays, and the cycle the first k-step reaches each PE. |
| [matrix_unit_tile_walkthrough.svg](svg/matrix_unit_tile_walkthrough.svg) | One K = 64 tile through the array: filling, steady state, capture and drain. |

## Verification plan (what exists today)

| Testbench | DUT | Stimulus | Checked against | Must happen or the run fails | Runs |
| --- | --- | --- | --- | --- | --- |
| `bpu_sa_pe_tb` | One PE | Every INT8 pair; every (INT8, INT4) pair in both halves; random modes, flags and drain shifts | Exact integer model of the accumulator and shadow | Drain shifts, captures, INT4 cycles (with `Int4`) | 3 builds × 1 seed |
| `bpu_sa_array_tb` | `bpu_sa_array` | Random tiles of random K; legal stalling producer; random out-ready; a streaming phase | Integer model: data, row index, order, latency (Rows + Cols − 1 edges) | Input stalls; zero stalls while streaming; an active reset | 8 shapes/modes × 3 seeds |
| `bpu_sa_scale_acc_tb` | `bpu_sa_scale_acc` | Directed IEEE boundary tiles; random tiles of 1–6 blocks; rows one per cycle | Independent binary32 model with full rounding (subnormals, infinity, NaN) | NaN, infinite, zero, subnormal and negative results; a reset with rows in flight | 3 shapes × 3 seeds |
| `bpu_sa_sram_wrapper_tb` | `bpu_sa_sram_wrapper` + `sram_arbiter_matrix_model` | Unscaled and block-scaled commands, INT8 and INT4, K at SRAM-row and scale-table boundaries plus random; illegal commands | Every C element in memory; exact read/write counts and bytes; port protocol (in the model) | Arbiter stalls (when ready < 100%); a reset while a command runs; scaled and INT4 commands | 9 configs × 3 seeds |

**Regression modes** (`tb/compute/Matrix_Unit/run_tests.sh`, VCS):
- **Default:** every run must pass.
- **`--inject-failure`:** every testbench corrupts one expected value, so every run must fail.
- **`--check-reset-guard`:** must fail with `active-reset precondition not reached`.

**The arbiter model** follows the [arbiter I/O scheme](../../memory/sram_arbiter_io_scheme.md):
- random request ready and a fixed response latency;
- one response pulse per read, in request order, with no backpressure;
- no response for writes, the default (one wrapper configuration also runs with write responses);
- random garbage in the bytes a read didn't ask for.

It checks the request protocol:
- a stalled request is still offered, unchanged, at the next edge;
- `req_valid` is never X or Z;
- addresses are row aligned, and `size_bytes` is in 1–512;
- reads stay inside the A, B and scale-table regions, and writes stay inside C with no X or Z bytes.

**Not covered yet:**
- coverage measurement;
- formal proofs, such as of the credit and ordering rules on the structure diagram;
- X propagation, since stimulus is two-state;
- integration with the real `sram_arbiter`;
- the command source, which is defined outside this unit.
