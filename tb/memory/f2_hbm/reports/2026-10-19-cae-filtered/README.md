# CAE HBM regression with filtered timing warnings

Tested implementation commit: `8b5e9a1985007c4c224207d2096434e697b56c10`.
Issue: [#25](https://github.com/SiliconBadgers/rtl/issues/25).
This report adds evidence without changing the tested implementation.

The run used VCS `Y-2026.03_Full64` on CAE host `linux-2005`,
Vivado 2024.2 simulation sources, and seed `1`. Dependency pins and
source hashes are in [summary.json](summary.json); the remote scratch path and
Git revision are in [remote.json](remote.json).

## Results

Four cases were planned, run and passed; zero failed or skipped. Compilation
and elaboration succeeded. Total remote compile/run time was
111.428 seconds. A passing negative case means that the simulator
returned nonzero with its required failure diagnostic.

| Case | Simulator exit | Regression result | Wall time (s) | Suppressed timing warnings |
| --- | --- | --- | --- | --- |
| read_write | 0 | Pass | 27.317 | 469,988 |
| bad_data | 3 | Pass | 12.280 | 194,356 |
| missing_reset | 3 | Pass | 1.824 | 0 |
| missing_backpressure | 3 | Pass | 20.478 | 407,380 |

The positive case checked all 32 AXI3 ports with burst lengths 1, 4 and 16:
672 accepted 256-bit writes, 672 checked read beats and 96 checked write
responses. It observed 144 AXI reset cycles, 1,856 stalled read cycles and
288 stalled write-response cycles. Data, IDs, response codes, final-beat flags
and response stability were checked with assertions enabled.

The corrupted-read, missing-reset and missing-backpressure cases each exited
with code 3 and retained their required diagnostic in the filtered log.
Every retrieved filtered log was compared against the raw log with only the
three identified timing-warning formats removed. All recorded suppression
counts matched; no identified timing-warning lines remained in the normal logs.

Local `make style` passed for eight SystemVerilog files and the Python tooling.
`make test-tooling` passed 25 tests in 2.509 seconds, including checks that the
filter preserves other warnings and errors. Replaying the prior full positive
log removed 469,988 identified timing warnings while preserving its completion
marker. Relative documentation links and `git diff --check` passed.

## Logs and reproduction

[compile.log](compile.log) contains the full compilation output.
[simulation-excerpts.log](simulation-excerpts.log) preserves completion and
expected-failure diagnostics.
[full-log-sha256.txt](full-log-sha256.txt) identifies the full filtered and raw
logs retained under `build/f2_hbm/sibadgers-f2-hbm.TYiMG8eK/` locally and the
scratch location in `remote.json` on CAE. CAE scratch is temporary.

From the RTL repository root with the prerequisites in
[the test guide](../../README.md):

```sh
make prepare-f2-hbm
make test-f2-hbm-cae F2_HBM_ARGS="--host YOUR_NETID@best-linux.cae.wisc.edu"
make style
make test-tooling
```

The recorded simulation used the equivalent dependency-free entry point:
`python3 scripts/f2_hbm.py remote --host ztaylor6@best-linux.cae.wisc.edu`.
Local checks used uv 0.12.23 through
`uv tool run --from uv==0.12.23 uv run --locked --group dev make UV=uv style test-tooling`.

Filtering changes log presentation only. Result classification uses raw output
and the simulator exit status; model timing checks and assertions remain active.
The underlying timing warnings remain unresolved. Coverage was not measured;
no bandwidth, timing closure, concurrent traffic, ECC recovery, full accelerator
or optional AWS `hbm_wrapper` verification is claimed.
