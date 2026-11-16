# Matrix-unit tests

These are the tests for the matrix unit in `rtl/compute/Matrix_Unit`; the source list is `bpu_sa_array.f`.

- **The array:** `bpu_sa_array`, `bpu_sa_pe`, `bpu_sa_delay` and the package `bpu_sa_pkg`. It's output-stationary and computes INT8 × INT8, or INT8 × INT4 at two k-steps per cycle, unscaled or block-scaled (each PE scales its block sums into a 48-bit fixed-point accumulator).
- **The SRAM wrapper:** `bpu_sa_sram_wrapper`, `bpu_sa_read_stream` and `bpu_sa_fifo`.

| Testbench | What it checks |
| --- | --- |
| `bpu_sa_pe_tb.sv` | One PE. Every signed INT8 pair (65,536) and, with `Int4`, every (INT8, INT4) pair in each half of the INT4-pair mode goes through a restart, one carry-save accumulation and a capture. Then random modes, tile flags, data and drain shifts run against a model. With `Scale`, 3,000 block-scaled tiles (1–4 blocks of 1–16 k-steps, random bf16 scales including huge, giant, tiny, zero, subnormal, inf and NaN, extreme operands, continued sums) run against an independent double-precision reference of the fixed-point contract; the run fails unless saturation, NaN, rounding to zero, a continued tile and a subnormal scale that only the flush keeps out of the sum (paired with a giant one) all occurred. Then the flag reset. |
| `bpu_sa_array_tb.sv` | One array shape and mode per run, unscaled or block-scaled (`Scaled`). Random tiles of random K run against a reference model, checking the data, index, order and latency of every C row. Block-scaled tiles are split into random blocks with random row and column scales, checked bit for bit against the fixed-point reference, with a fifth of the tiles continuing the previous sums. It also checks stalled k-steps under a legal producer, `in_ready_o` every cycle, a streaming phase that must never stall, an active reset, and the mode error. In INT8 mode it puts junk in the unused high A byte; outside a block's last k-step it puts junk in the scale inputs. |
| `bpu_sa_sram_wrapper_tb.sv` | One wrapper configuration per run, against the model below. It runs unscaled and block-scaled commands, in INT8 and INT4. The K values are directed at SRAM-row and scale-table-row boundaries, plus random K. Commands are also chained along K with `cmd_clear_acc_i` / `cmd_write_output_i`, in directed chains (including an INT8/INT4 switch right after a command that keeps its sums) and at random. Every C element written is checked against an independent reference that carries kept sums across commands, and a command that keeps its sums must write nothing. Illegal continuations (nothing kept, the wrong kind, after a reset) must be rejected. It also checks exact read and write counts per stream, illegal commands, a reset while a command is certainly running, and the `busy_o` / `done_o` / `err_o` / `cmd_ready_o` rules. When the arbiter isn't always ready, a run fails unless request stalls occurred. |
| `bpu_sa_sram_wrapper_golden_tb.sv` | Real tensors. It runs the commands of `bpu_sa_golden_vectors_pkg` against the model below and checks every C element bit for bit, under arbiter stalls. The commands are 8 × 8 tiles with K = 2048 from Qwen3.5-2B: an INT4 tile (from a Q4_K weight), an INT8 tile (from Q5_K), the INT4 tile split across two chained commands, and an unscaled INT8 tile. A command that keeps its sums must write nothing. The run fails unless every command completed and every C element was checked. |
| `bpu_sa_golden_vectors_pkg.sv` | Generated; do not edit. It holds the memory image, the command list and the expected C for `bpu_sa_sram_wrapper_golden_tb`. The golden model's `tools/export_rtl_vectors.py` writes it, from the pinned Qwen3.5-2B Q4_K_M model file (the header records its hash). The expected values come from its model of this unit's arithmetic contract. |
| `sram_arbiter_matrix_model.sv` | A testbench model of the `sram_arbiter` matrix port with an SRAM behind it. It gives random ready, a fixed response latency and, as the arbiter specifies, no response for writes (`WriteAcks = 1` adds them for one configuration), and puts random garbage above `size_bytes` in read data. It checks the port protocol: stable stalled requests, alignment, sizes, reads only inside the command's four read windows, and writes only inside C. |

## Run

You need Bash 3.2+, uv 0.12.23+, Python 3.11+, Git and Synopsys VCS `Y-2026.03_Full64`. On CAE, run `module load synopsys/vcs-mx/2026.03` first, then `make setup` once to create the locked tool environment. The runner checks the pinned version and does not fall back to another simulator; see [the setup guide](../../../SETUP.md).

From the repository root:

```sh
make test-matrix-unit
```

or directly, with options:

```sh
bash tb/compute/Matrix_Unit/run_tests.sh --seeds "1 2 3"
bash tb/compute/Matrix_Unit/run_tests.sh --only wrap_8x8_lat4 --seeds 7
```

The runner builds and runs every configuration in its `CONFIGS` table:

- **PE:** three builds, at two widths, with and without `Int4` and `Scale`.
- **Array:** eleven shapes and modes, three of them block-scaled (INT8, INT4, and the narrowest `AccW` = 25 with block size 32).
- **Wrapper:** nine configurations. They cover shapes, latencies, ready rates, writes with and without responses, buffer depths, block size 32, a 256-bit SRAM row, and builds without `Int4` and without `Scale`.
- **Real tensors:** `wrap_8x8_golden`, `bpu_sa_sram_wrapper_golden_tb` on the generated vectors.

The array, wrapper and real-tensor configurations run three seeds each. That's 24 configurations and 66 runs.

The runner enforces compile and simulation timeouts. It exits nonzero on a compile error, a failed or missing result, or a timeout. Each run must end with one `RESULT ... status=PASS` line and a zero exit status; the testbenches call `$fatal(1, ...)` on any failure.

Outputs go to `build/matrix_unit/vcs/`, which is not committed:

- one log per run in `logs/`
- a `summary.md` table with the tested commit, the simulator version, the counts and the elapsed time

To check that failures are detected, run with `--inject-failure`. Every testbench then corrupts one expected value, every run must fail, and the runner must exit 1.

### Active-reset guard

The array test's reset needs a finished tile still draining while the next tile accumulates.

1. It waits at most `ResetWaitCycles` extra stimulus cycles for that point, then stops with `$fatal` and `active-reset precondition not reached`.
2. Once the point is reached, it lets the rising edge accept the prepared transfer, then asserts reset.
3. Every array result must report `active_resets=1`.

The wrapper test likewise fails if its reset never catches a running command.

Exercise the missing-condition failure separately:

```sh
bash tb/compute/Matrix_Unit/run_tests.sh --check-reset-guard --out build/reset_guard
```

This disables the traffic phase and the wait for active work. Expect exit status 1 and `active-reset precondition not reached` in the simulation log. A compile error or any other failure reason does not validate this check.

### Notes

**Assertions:**
- Assertions stay enabled through `-assert svaext`. The labelled ones are `CaptureShiftExclusive_A`, `NoOverflow_A`, `NoUnderflow_A`, `GrantWanted_A`, `StartIdle_A`, `ExpectedResponse_A`, `NoReadWriteOverlap_A` and the testbench monitors.
- Every simulator invocation uses `-exitstatus`, so assertion and testbench fatal failures reach the shell.

**Runner:**
- Compile commands and elapsed time are recorded under `build/<configuration>/`.
- The runner uses `scripts/vcs.py` for version checks, CAE and native invocation, and bounded execution. It rejects `--sim icarus` and `--sim verilator`.

**Logs:**
- A rerun overwrites only matching output files. Use separate `--out` directories for positive and negative runs to keep both results.
- `planned` counts selected configuration and seed pairs, `run` counts simulator processes started, and `failed` includes compilation failures.

**Seeds:** random stimulus uses a built-in xorshift32 generator seeded from `+seed=<n>`, so a given seed produces the same stimulus on every simulator. To rerun a failing seed, use `--only <configuration> --seeds <n>`.
