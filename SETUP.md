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

The default suite runs 17 configuration/seed pairs. Logs and the result table
are written under `build/matrix_unit/vcs/`. See
[the test instructions](tb/compute/Matrix_Unit/README.md) for failure injection,
reset prerequisites, configuration selection and result counts.

## Independent MAC example

With Architecture, Software and Verification checked out as siblings:

```sh
make test MODELS_ROOT=../software CONTRACT=../architecture/contracts/mac-v0.json VERIFICATION_ROOT=../verification
```

This generates reference vectors and runs the independent Verification
repository's `tb/pe_mac_smoke_tb.sv` against this checkout's
`rtl/compute/pe_mac.sv`, using VCS. Use the coordinated VCS-enabled `run.py` revision in Verification. Logs, input hashes and actual counts are saved under the
Verification checkout's `build/mac/vcs/`. The example checks MAC arithmetic and pipeline
behavior, not the complete accelerator.

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
