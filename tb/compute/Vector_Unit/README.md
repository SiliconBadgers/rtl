# Vector-unit tests

Tests for the SIMD vector unit in `rtl/compute/Vector_Unit` (top `vec_simd`; source list
`vec_simd.f`). The unit implements the 135 signatures of the
[32-bit SIMD ISA](../../../docs/simd-isa.md).

| Testbench | What it checks |
| --- | --- |
| `vec_simd_tb.sv` | 125 directed checks at `NumLanes = 4`. Builds every value from zero registers through commands, then checks SETVL, scalar and vector ADD/SUB, IOTA, PERMUTE, EQ/LT with a masked ADD, PAND, PNOT (lanes at or above VL kept), vector and scalar SELECT, CAST I32↔F32, FMA.F32, DIV.F32 (multi-cycle), vector and scalar DIVMOD, RSQRT, EXP, REDUCE SUM/MAX, the ADD_SAT saturation count, an illegal command, the sticky fault, reset recovery, divide by zero writing nothing and SETVL above `NumLanes`. |

A check is one comparison of a register, flag or counter with its expected value; a
vector register compare counts once per lane. The run fails if any check fails or if
fewer than 125 checks run.

## Run

From the repository root, with Synopsys VCS `Y-2026.03_Full64` and uv (on CAE, run
`module load synopsys/vcs-mx/2026.03` first; see [the setup guide](../../../SETUP.md)):

```sh
make test-vector-unit
```

With ModelSim or Questa (`vlib`, `vlog`, `vsim` on PATH) and Python 3.11+:

```sh
bash tb/compute/Vector_Unit/run_tests.sh --sim modelsim
```

Interactive ModelSim session (GUI or console), from the repository root:

```sh
vsim -do tb/compute/Vector_Unit/run_modelsim.do
```

Negative check: `--inject-failure` makes the testbench expect one wrong value, so the
run must report `status=FAIL` and the runner must exit 1.

```sh
bash tb/compute/Vector_Unit/run_tests.sh --sim modelsim --inject-failure
```

Results are written to `build/vector_unit/<sim>/summary.md`, with the simulator output
in `build/vector_unit/<sim>/logs/vec_simd_tb.log` and the compile output in
`build/vector_unit/<sim>/build.log`.

## Known limitations

- Directed tests at one lane count only; no random testing and no coverage measured.
- The arithmetic units (FP add/sub, FMA, CAST, DIV, RSQRT, EXP, integer division) were
  checked separately against exact and MPFR reference models during development; those
  models are not part of this regression.
- There is no external register load/store port yet, so the testbench reads registers
  through the hierarchy (`u_dut.u_register_file`).
