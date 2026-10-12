# Matrix-unit systolic array tests

Tests for the int8 systolic array in `rtl/compute/Matrix_Unit`
(`bpu_sa_array`, `bpu_sa_pe`, `bpu_sa_delay`; source list `bpu_sa_array.f`).

| Testbench | What it checks |
| --- | --- |
| `bpu_sa_pe_tb.sv` | One PE. Every signed int8 pair (65,536) through the shadow path and again through the active path, with random incoming sum and carry; the swap_o reset. |
| `bpu_sa_array_tb.sv` | One array shape per run. Random A tiles and B columns against a reference model (data, order and latency of every C column), stalled A rows held by a legal producer, a reset during active work, and the int4 mode error. |

## Run

Prerequisites: bash, GNU coreutils `timeout`, Git, and either Icarus Verilog
(`iverilog`, `vvp`; tested with 14.0 devel) or Verilator 5 (tested with 5.053).

From the repository root:

```sh
make test-matrix-unit
```

or directly, with options:

```sh
bash tb/compute/Matrix_Unit/run_tests.sh --sim verilator --seeds "1 2 3"
bash tb/compute/Matrix_Unit/run_tests.sh --only array_8x8_acc32 --seeds 7
```

The runner builds and runs every configuration in its `CONFIGS` table (two PE
widths, five array shapes, three seeds each), enforces a per-run timeout, and exits
nonzero on a compile error, a failed or missing result, or a timeout. Each run
must end with one `RESULT ... status=PASS` line and a zero exit status; the
testbenches call `$fatal(1, ...)` on any failure.

Outputs go to `build/matrix_unit/<sim>/`: one log per run in `logs/` and a
`summary.md` table with the tested commit, simulator version, counts and elapsed
time. `build/` is not committed.

To check that failures are detected, run with `--inject-failure`: every
testbench corrupts one expected value, every run must fail, and the runner must
exit 1.

Random stimulus uses a built-in xorshift32 generator seeded from `+seed=<n>`,
so a seed produces the same stimulus on every simulator; rerun a failing seed
with `--only <configuration> --seeds <n>`.
