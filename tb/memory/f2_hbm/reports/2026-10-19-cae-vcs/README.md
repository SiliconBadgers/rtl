# CAE F2 HBM functional regression

Tested implementation commit: `9f803c68ba54d38abd5a0cb129da51f7b0558f77`.
This report was added afterward without changing the tested sources.
Issue: [#25](https://github.com/SiliconBadgers/rtl/issues/25).

The run used VCS `Y-2026.03_Full64`, Vivado 2024.2 simulation sources,
Python 3.13.5 on CAE host `linux-2013`, and data seed `1`.
AWS FPGA revision: `c34f88e97eaf8a9b6ea7a3516ab65ee64690ab82`.
AWS resources revision: `ce27e8888f7a07c34316ebcbc786505d7e5440a7`.
Source hashes and the staged vendor-manifest hash are in
[summary.json](summary.json).

## Results

Four cases were planned, run and passed; zero failed or skipped. A passing
negative case means that `simv -exitstatus` returned nonzero and the expected
failure diagnostic was present. Compilation and elaboration also succeeded.
Total remote compilation and simulation time: 102.313 seconds.

| Case | Simulator exit | Regression result | Wall time (s) | Vendor timing warnings |
| --- | --- | --- | --- | --- |
| read_write | 0 | Pass | 24.910 | 469,988 |
| bad_data | 3 | Pass | 13.118 | 194,356 |
| missing_reset | 3 | Pass | 2.576 | 0 |
| missing_backpressure | 3 | Pass | 20.253 | 407,380 |

The positive case checked all 32 AXI3 ports: 672 accepted 256-bit writes,
672 read-data/ID/response/last-beat comparisons and 96 write-response/ID checks.
It observed 144 AXI reset cycles, 1,856 stalled read cycles and 288 stalled
write-response cycles. Each port exercised burst lengths of 1, 4 and 16 beats.
Read/write response-stability assertions were enabled.

The negative cases exercised a corrupted expected read value, an omitted reset
assertion and omitted response backpressure. Their diagnostic markers were
`HBM_DATA_MISMATCH`, `HBM_RESET_REQUIRED` and `HBM_BACKPRESSURE_REQUIRED`.
Coverage was not measured. No synthesis, formal, physical timing, concurrent
traffic, ECC recovery or full-accelerator results are claimed.

## Diagnostics and logs

[compile.log](compile.log) is the full compilation log.
[simulation-excerpts.log](simulation-excerpts.log) contains completion and
failure diagnostics plus representative vendor warnings from each simulation.
[full-log-sha256.txt](full-log-sha256.txt) identifies the complete simulation
logs, retained locally under
`build/f2_hbm/sibadgers-f2-hbm.bvssfXDd/<case>/run.log` and in CAE scratch
`/tmp/sibadgers-f2-hbm.bvssfXDd/build/f2_hbm/<case>/run.log`.
The scratch copy is temporary; the committed summary and excerpts preserve
this run's checks and limitations.

The model emitted `tCHmax` and IEEE1500 timing warnings. These remain unresolved;
a functional pass is not evidence of accurate model timing or achievable HBM
bandwidth. The compiler also reported six unused vendor VIP interfaces. No
warning suppression was added.

## Reproduce

From the RTL repository root with the prerequisites in
[the test guide](../../README.md):

```sh
make prepare-f2-hbm
make test-f2-hbm-cae F2_HBM_ARGS="--host YOUR_NETID@best-linux.cae.wisc.edu"
```

The local run used `/home/zeb/opt/Xilinx/Vivado/2024.2` for preparation and
`ztaylor6@best-linux.cae.wisc.edu` as the SSH destination. The Make targets were
exercised with uv 0.12.23 via `uv tool run --from uv==0.12.23 uv run --locked make
UV=uv ...`, since the workstation's default uv was older than the repository pin.

Local validation: `make style` passed for eight SystemVerilog sources and the
Python tooling; `make test-tooling` passed 23 tests in 4.071 seconds. Relative
links in the new guide and setup page and `git diff --check` also passed.
