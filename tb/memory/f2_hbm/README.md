# AWS F2 HBM simulation on CAE

Run the AWS-configured, two-stack AMD HBM model in VCS without installing
Vivado on CAE. The runner stages simulation sources from local Vivado 2024.2,
copies this checkout to CAE scratch, compiles through
[`scripts/vcs.py`](../../../scripts/vcs.py), and retrieves results.

This test exercises the HBM model directly. It does not instantiate the AWS
PCIe shell, a SiliconBadgers memory controller, or the complete accelerator.
It is a functional integration check, not a bandwidth benchmark.

## Prepare the local checkout

Use Python 3.11+, Git, and a Vivado 2024.2 installation. No Python packages or
Git LFS executable are required by the runner. From the repository root:

```sh
make prepare-f2-hbm F2_HBM_ARGS="--vivado /path/to/Xilinx/Vivado/2024.2"
```

The dependency revisions are pinned in [dependencies.json](dependencies.json).
Preparation creates these ignored directories inside this repository:

| Directory | Contents |
| --- | --- |
| `third_party/aws-fpga/` | AWS FPGA F2 checkout and its Vivado 2024.2 resources checkout at `hdk/common/ip/` |
| `third_party/vivado-2024.2/` | XPM, VIP, UNISIM, two-stack HBM SECUREIP, and a SHA-256 manifest |

Only the six required Git LFS model/source pointers are downloaded from the
pinned AWS resources revision. Each download is checked against the pointer's
size and SHA-256. Synthesis checkpoints and unrelated IP models remain unused.
Vendor files retain their notices and stay out of Git. Preparation copies the
required Vivado sources; it does not run Vivado or copy license files. The
staged simulation files occupy approximately 173 MB before compression.

Compilation follows AWS's
[exported VCS script](https://github.com/aws/aws-fpga-resources/blob/ce27e8888f7a07c34316ebcbc786505d7e5440a7/cl_ip/cl_ip.ip_user_files/sim_scripts/cl_hbm/vcs/cl_hbm.sh),
with two-stack SECUREIP sources and UNISIM supplied directly to VCS.
The SystemVerilog test does not need the script's VHDL XPM component
declarations. `+define+VCS` selects the VCS memory model. Each simulation
working directory receives the HBM configuration `.mem` files.

## Copy to CAE and run

SSH authentication must already work for your CAE account. The remote host needs
Python 3.11+, rsync, and `synopsys/vcs-mx/2026.03`. The simulator must report the
repository baseline, `Y-2026.03_Full64`.

```sh
make test-f2-hbm-cae F2_HBM_ARGS="--host YOUR_NETID@best-linux.cae.wisc.edu"
```

The runner uses one SSH control connection for scratch allocation, rsync,
compilation, simulation, and log retrieval. This keeps every operation on the
same machine behind CAE's load balancer. It copies the repository, including
the ignored vendor bundle, while excluding Git metadata, `.venv`, and build
outputs. It does not delete or replace an existing CAE checkout.

The remote command loads the VCS module on the CAE host. Python runs on that
host; the existing helper invokes VCS and `simv -exitstatus` through
`synopsys-run`. Assertions stay enabled. The default wall-clock limit is 1,200
seconds for compilation and each simulation; the testbench also has a 1 ms
simulation-time watchdog. Set `--timeout SECONDS` and `--seed NUMBER` through
`F2_HBM_ARGS` to override the defaults.

The scratch path is printed at startup and retained for debugging. Logs and
JSON reports are copied back to `build/f2_hbm/<scratch-name>/`, including when a
simulation fails. Each invocation gets a separate results directory. Use
`--output PATH` to change its parent directory. Run `simulate`
directly in the retained checkout to debug that exact source snapshot.

If you already have licensed VCS locally:

```sh
make test-f2-hbm
```

The dependency-free Python entry point is also available directly, for example
`python3 scripts/f2_hbm.py remote --host YOUR_NETID@best-linux.cae.wisc.edu`.
The Make targets use the repository's locked uv environment.
Set `RTL_CAE_HOST=YOUR_NETID@best-linux.cae.wisc.edu` to omit `--host` on later
runs. The model sources are from Vivado 2024.2; CAE uses the project's VCS 2026.03
pin, rather than AWS's published VCS 2023.12 pairing for that Vivado release.
The checked regression establishes this combination's tested functional scope.

## Checks and results

The positive case writes all channels before reading them back to expose
address aliasing. Each of the 32 AXI3 ports transfers bursts of 1, 4 and 16
beats into separate regions of its 512 MiB pseudo-channel. Data patterns
include the seed, channel, burst, beat and 32-bit word index.

Required counts are 672 accepted 256-bit writes, 672 checked read beats, and
96 checked write responses. The test compares read data, IDs, response codes
and `RLAST`, observes reset cycles and stalled read/write responses, and
asserts response stability during backpressure. A missing prerequisite or
incomplete count fails the case.

The same binary runs three expected-failure cases: a corrupted read
expectation, omitted reset assertion, and omitted response backpressure.
Each must exit nonzero with its specific diagnostic. A timeout, missing
completion marker, or unrelated simulator/license failure cannot count as a
passing case.

`summary.json` records the four case outcomes, observed positive counts,
elapsed times, seed, simulator baseline, dependency pins and source hashes.
`compile.log` and `<case>/run.log` contain detailed diagnostics. `remote.json`
records the SSH destination, retained scratch path and local Git revision.
Coverage is not measured. The cases do not establish performance, concurrent
traffic behavior, ECC recovery, APB monitoring, or hardware timing closure.

The vendor model emits `tCHmax` and IEEE1500 timing warnings in this setup.
The runner retains them in the logs and records their count for each case;
the functional pass does not resolve those warnings or establish timing-model
accuracy. Compiler messages about unused VIP interfaces also remain visible.

Run Python failure-classification checks with `make test-tooling`.
