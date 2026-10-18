# RTL setup

Synopsys VCS is the required simulator. The pinned version is
`Y-2026.03_Full64`, available on UW–Madison CAE Linux through:

```sh
module load synopsys/vcs-mx/2026.03
make doctor
make test-matrix-unit
```

Use Bash 3.2+, Python 3.11+, Git and Make. Run Python and Make on the CAE host;
`scripts/vcs.py` invokes the compiler and simulator through `synopsys-run`.
On another licensed Linux installation it invokes `vcs` and `simv` directly.
`VCS_LAUNCHER` can select a site launcher; an explicitly empty value selects
native execution. Launcher arguments are parsed without a shell. No licenses,
license-server addresses or licensed tools belong in Git.

The helper rejects missing tools and compiler versions other than the pin.
It compiles with `-sverilog -timescale=1ns/1ps -assert svaext` and runs with
`-exitstatus`, so `$fatal` returns a failure to the regression. Compilation and
simulation both have timeouts. Tool upgrades require a validated pin change.

VCS is required for RTL simulation results. Verilator may be used for lint;
Icarus and Verilator are not alternate simulation backends. The GitHub source
style job checks formatting, lint and Python tooling; it does not run licensed
simulation or establish that a VCS regression passed. Include CAE run evidence
in the PR as described in [CONTRIBUTING.md](CONTRIBUTING.md).

## Matrix-unit regression

```sh
make test-matrix-unit
make test-matrix-unit MATRIX_UNIT_ARGS="--only array_8x8_acc32 --seeds 7"
python3 -m unittest discover -s scripts -p 'test_*.py'
```

The default suite runs 63 configuration/seed pairs across 23 configurations:
the PE, the array, the block-scaling stage, and the SRAM wrapper against a model
of the arbiter. Logs and the result table are written under
`build/matrix_unit/vcs/`. See
[the test instructions](tb/compute/Matrix_Unit/README.md) for failure injection,
reset prerequisites, configuration selection and result counts.

## Default test entry point

`make test` runs the same current Matrix Unit regression as
`make test-matrix-unit`, including `MATRIX_UNIT_ARGS` selection. It no longer
requires the Software vector generator, the standalone MAC contract or the
retired independent MAC runner in Verification. The obsolete MAC DUT and its
legacy coverage are removed, not relocated or silently skipped. The Matrix
Unit tests cover the unit's blocks and its SRAM wrapper against a model of the
arbiter, not the retired accumulator interface or full-accelerator integration. Existing dated reports remain
historical evidence for their recorded revisions.

## Source style

Install Verible v0.0-3946-g851d3ff4 and Ruff 0.16.6, and put their executables on
PATH. CI pins those versions and checks only tracked project sources.

```sh
make style
make format
```

Verible formats and lints SystemVerilog. Ruff formats and lints Python tooling.
Generated build products, external dependencies and licensed collateral do not
belong in Git.

`style.json` requires UpperCamelCase parameters and ALL_CAPS localparams,
matching the published coding standard. Run `make style` after removing obsolete naming
waivers; do not relax the rule to allow both styles.
