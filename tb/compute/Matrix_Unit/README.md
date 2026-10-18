# Matrix-unit tests

These are the tests for the matrix unit in `rtl/compute/Matrix_Unit`; the source list is `bpu_sa_array.f`.

- **The array:** `bpu_sa_array`, `bpu_sa_pe` and `bpu_sa_delay`. It's output-stationary and computes INT8 × INT8, or INT8 × INT4 at two k-steps per cycle.
- **The block-scaling stage:** `bpu_sa_scale_acc`.
- **The SRAM wrapper:** `bpu_sa_sram_wrapper`, `bpu_sa_read_stream` and `bpu_sa_fifo`.
- **The FP32 units** in `rtl/compute/fp`, `rtl/compute/common` and `rtl/common/bpu_compute_pkg.sv`.

| Testbench | What it checks |
| --- | --- |
| `bpu_sa_pe_tb.sv` | One PE. Every signed INT8 pair (65,536) and, with `Int4`, every (INT8, INT4) pair in each half of the INT4-pair mode goes through a restart, one carry-save accumulation and a capture. Then random modes, tile flags, data and drain shifts run against a model. Then the flag reset. |
| `bpu_sa_array_tb.sv` | One array shape and mode per run. Random tiles of random K run against a reference model, checking the data, index, order and latency of every C row. It also checks stalled k-steps under a legal producer, `in_ready_o` every cycle, a streaming phase that must never stall, an active reset, and the mode error. In INT8 mode it puts junk in the unused high A byte. |
| `bpu_sa_scale_acc_tb.sv` | The block-scaling stage on its own, every output bit against an independent IEEE binary32 reference (subnormals, overflow to infinity, NaN). Directed tiles cover signed zeros, the largest and smallest block sums, cancellation, infinity minus infinity, a NaN scale, 0 × infinity, underflow and subnormal results. Random tiles have 1–6 blocks with random row order and gaps. It checks the 8-cycle latency, idle cycles with junk payload, and a reset with rows in flight. A run fails unless NaN, infinite, zero, subnormal and negative results all occurred. |
| `bpu_sa_sram_wrapper_tb.sv` | One wrapper configuration per run, against the model below. It runs unscaled and block-scaled commands, in INT8 and INT4. The K values are directed at SRAM-row and scale-table-row boundaries, plus random K. Every C element in memory is checked against an independent reference. It also checks exact read and write counts per stream, illegal commands, a reset while a command is certainly running, and the `busy_o` / `done_o` / `err_o` / `cmd_ready_o` rules. When the arbiter isn't always ready, a run fails unless request stalls occurred. |
| `sram_arbiter_matrix_model.sv` | A testbench model of the `sram_arbiter` matrix port with an SRAM behind it. It gives random ready, a fixed response latency and, as the arbiter specifies, no response for writes (`WriteAcks = 1` adds them for one configuration), and puts random garbage above `size_bytes` in read data. It checks the port protocol: stable stalled requests, alignment, sizes, reads only inside the command's four read windows, and writes only inside C. |

## Run

You need Bash 3.2+, Python 3.11+, Git and Synopsys VCS `Y-2026.03_Full64`. On CAE, run `module load synopsys/vcs-mx/2026.03` first. The runner checks the pinned version and does not fall back to another simulator; see [the setup guide](../../../SETUP.md).

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

- **PE:** three builds, at two widths, with and without `Int4`.
- **Scale stage:** three shapes and sum widths.
- **Array:** eight shapes and modes.
- **Wrapper:** nine configurations. They cover shapes, latencies, ready rates, writes with and without responses, buffer depths, block size 32, a 256-bit SRAM row, and builds without `Int4` and without `Scale`.

The scale, array and wrapper configurations run three seeds each.

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

The wrapper and scale tests likewise fail if their reset never catches a running command or rows in flight.

Exercise the missing-condition failure separately:

```sh
bash tb/compute/Matrix_Unit/run_tests.sh --check-reset-guard --out build/reset_guard
```

This disables the traffic phase and the wait for active work. Expect exit status 1 and `active-reset precondition not reached` in the simulation log. A compile error or any other failure reason does not validate this check.

### Notes

**Assertions:**
- Assertions stay enabled through `-assert svaext`. The labelled ones are `CaptureShiftExclusive_A`, `NoOverflow_A`, `NoUnderflow_A`, `GrantWanted_A`, `StartIdle_A`, `ExpectedResponse_A`, `NoReadWriteOverlap_A`, `RowReuseSpacing_A` and the testbench monitors.
- Every simulator invocation uses `-exitstatus`, so assertion and testbench fatal failures reach the shell.

**Runner:**
- Compile commands and elapsed time are recorded under `build/<configuration>/`.
- The runner uses `scripts/vcs.py` for version checks, CAE and native invocation, and bounded execution. It rejects `--sim icarus` and `--sim verilator`.

**Logs:**
- A rerun overwrites only matching output files. Use separate `--out` directories for positive and negative runs to keep both results.
- `planned` counts selected configuration and seed pairs, `run` counts simulator processes started, and `failed` includes compilation failures.

**Seeds:** random stimulus uses a built-in xorshift32 generator seeded from `+seed=<n>`, so a given seed produces the same stimulus on every simulator. To rerun a failing seed, use `--only <configuration> --seeds <n>`.
