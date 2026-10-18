# FP32 units, and their helpers

These files are copied from the BPU compute library, a separate repository kept by the Matrix Unit's author (its `compute/rtl/fp` and `compute/rtl/common`, last changed in `f3d9eea`, 2026-10-02). The paths below under "compute library" refer to that repository, not this one. `bpu_sa_scale_acc` uses them for block scaling.

The only changes are layout: the Verible formatter (whitespace and line wrapping only) and one long line wrapped by hand, so that `make style` passes. The logic is unchanged, and the matrix-unit regression was rerun after formatting.

| File | What it is |
| --- | --- |
| `bpu_int2fp32.sv` | Signed integer to IEEE binary32. Exact for inputs up to 25 bits. |
| `bpu_fp32_mul.sv` | IEEE binary32 multiply: round to nearest even, subnormals, canonical NaN, 3 configurable pipeline stages. |
| `bpu_fp32_add.sv` | IEEE binary32 add, with the same rounding and pipeline options. |
| `rtl/common/bpu_compute_pkg.sv` | Numerics constants, including `FP32_QNAN`. |
| `rtl/compute/common/bpu_delay.sv`, `bpu_lzc.sv`, `bpu_lzc_pow2.sv` | Delay line and leading-zero count. |

In the compute library, `scripts/soak_fp32.sh` checks them against the host FPU:

- 100 million random vectors each for the multiplier and the adder
- every bf16 × bf16 product (2³²)
- every int → fp32 conversion (2²²)

The results are in `compute/docs/verification.md`. Gate-level netlists of the engines that use these units pass the same cocotb tests.

They predate coding standard v1.1, and their structure still differs from it: several declarations per line and compact port connections. That is recorded here as an exception for reused, already-verified code. They pass Verible format and lint, and Verilator `-Wall` is clean on them as instantiated here.
