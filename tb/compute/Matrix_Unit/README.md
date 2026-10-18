# Matrix-unit systolic array tests

Tests for the int8 systolic array in `rtl/compute/Matrix_Unit`
(`bpu_sa_array`, `bpu_sa_pe`, `bpu_sa_delay`; source list `bpu_sa_array.f`).

| Testbench | What it checks |
| --- | --- |
| `bpu_sa_pe_tb.sv` | One PE. Every signed int8 pair (65,536) through the shadow path and again through the active path, with random incoming sum and carry; the swap_o reset. |
| `bpu_sa_array_tb.sv` | One array shape per run. Random A tiles and B columns against a reference model (data, order and latency of every C column), stalled A rows held by a legal producer, a reset during active work, and the int4 mode error. |

## Run

Prerequisites: Bash 3.2+, uv 0.12.23+, Python 3.11+, Git and Synopsys VCS
`Y-2026.03_Full64`. On CAE, run `module load synopsys/vcs-mx/2026.03`
first. The runner checks the pinned version and does not fall back to another
simulator. See [the setup guide](../../../SETUP.md).

From the repository root:

```sh
make test-matrix-unit
```

or directly, with options:

```sh
bash tb/compute/Matrix_Unit/run_tests.sh --seeds "1 2 3"
bash tb/compute/Matrix_Unit/run_tests.sh --only array_8x8_acc32 --seeds 7
```

The runner builds and runs every configuration in its `CONFIGS` table (two PE
widths, five array shapes, three seeds each), enforces compile and simulation timeouts, and exits
nonzero on a compile error, a failed or missing result, or a timeout. Each run
must end with one `RESULT ... status=PASS` line and a zero exit status; the
testbenches call `$fatal(1, ...)` on any failure.

Outputs go to `build/matrix_unit/vcs/`: one log per run in `logs/` and a
`summary.md` table with the tested commit, simulator version, counts and elapsed
time. `build/` is not committed.

To check that failures are detected, run with `--inject-failure`: every
testbench corrupts one expected value, every run must fail, and the runner must
exit 1.

The reset test requires at least one queued column and, for multi-row arrays, a
partially loaded A tile. It waits at most `ResetWaitCycles` additional stimulus
cycles, then fails if those conditions are absent. It waits for the rising edge
to accept the prepared transfer before asserting reset. Every array result must
report `active_resets=1`; multi-row configurations also require
`partial_load_resets=1`. A 1-row array cannot contain a partially loaded tile.

Exercise the missing-condition failure separately:

```sh
bash tb/compute/Matrix_Unit/run_tests.sh --check-reset-guard --out build/reset_guard
```

This disables the initial traffic phase and the wait for active work. Expect exit
status 1 and `active-reset precondition not reached` in the simulation log; a
compile error or another failure reason does not validate this check.

Assertions remain enabled through `-assert svaext`. The immediate stall
assertion retains its descriptive `AStallStable_A` label. The compiler uses
`-timescale=1ns/1ps` as the default for modules without explicit time units;
explicit testbench declarations remain in force. Every simulator invocation
uses `-exitstatus` so assertion/testbench fatal failures reach the shell.

Compile commands and elapsed time are recorded under `build/<configuration>/`.
The runner uses `scripts/vcs.py` for version checks, CAE/native invocation and
bounded execution. It rejects `--sim icarus` and `--sim verilator`.

Logs are retained and a rerun overwrites only matching output files. Use separate
`--out` directories for positive and negative runs to preserve both results.
`planned` counts selected configuration/seed pairs, `run` counts simulator
processes started, and `failed` includes compilation failures. Python supplies
wall-clock time and timeout termination on macOS and Linux.

Random stimulus uses a built-in xorshift32 generator seeded from `+seed=<n>`,
so a seed produces the same stimulus on every simulator; rerun a failing seed
with `--only <configuration> --seeds <n>`.
