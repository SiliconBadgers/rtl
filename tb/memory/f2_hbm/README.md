# AWS F2 HBM simulation on CAE

Run the AWS-configured, two-stack AMD HBM model in VCS without installing
Vivado on CAE. The runner stages simulation sources from local Vivado 2024.2,
copies this checkout to CAE scratch, compiles through
[`scripts/vcs.py`](../../../scripts/vcs.py), and retrieves results.

This test exercises the HBM model directly. It does not instantiate the AWS
PCIe shell, a SiliconBadgers memory controller, or the complete accelerator.
It is a functional integration check, not a bandwidth benchmark.

## HBM interface

The generated `cl_hbm` module exposes 32 AXI3 slave ports, `AXI_00` through
`AXI_31`, across two HBM stacks with 16 GiB total capacity. Our logic acts as
the AXI master. Each port has these widths:

| Signals | Width and meaning |
| --- | --- |
| `WDATA`, `RDATA` | 256 bits, or 32 bytes per accepted beat |
| `AWADDR`, `ARADDR` | 34-bit byte address |
| `AWID`, `ARID`, `BID`, `RID` | 6-bit transaction ID |
| `AWLEN`, `ARLEN` | 4 bits; burst length minus one, for 1–16 beats |
| `AWSIZE`, `ARSIZE` | Set to `5` for 32-byte beats |
| `WSTRB` | 32 byte enables |
| `BRESP`, `RRESP` | 2-bit response status |

Address, data and response channels use independent `VALID`/`READY` handshakes.
Writes use `AW`, `W` and `B`; reads use `AR` and `R`. Hold a request or data
beat stable until its handshake, assert `WLAST` on the final write beat, and
check `RLAST` on the final read beat. Responses have variable latency.

With global addressing enabled in this configuration, each port can address
the full HBM space through the internal switch. Address bit `[33]` selects
the stack, `[32:29]` selects one of its 16 pseudo-channels, and `[28:0]` is
the byte offset within a 512 MiB pseudo-channel. Use 32-byte-aligned addresses.
See AMD's [address map](https://docs.amd.com/r/en-US/pg276-axi-hbm/HBM-Address-Map-and-Protocol-Considerations)
and [AXI requirements](https://docs.amd.com/r/en-US/pg276-axi-hbm/AXI-Considerations).

The native IP also has per-port clocks and active-low resets, two 100 MHz
reference clocks, two APB control interfaces, per-stack initialization and
temperature status, data-parity signals, and APB monitor connections for the
AWS shell. Wait for both `apb_complete` outputs before sending traffic.
For an AFI, connect the shell monitor interfaces as specified in AWS's
[shell interface guide](https://github.com/aws/aws-fpga/blob/c34f88e97eaf8a9b6ea7a3516ab65ee64690ab82/hdk/docs/AWS_Shell_Interface_Specification.md#hbm-monitor-interface).

AWS's optional [`hbm_wrapper`](https://github.com/aws/aws-fpga/blob/c34f88e97eaf8a9b6ea7a3516ab65ee64690ab82/hdk/common/lib/hbm_wrapper.sv)
accepts a configurable number of ports and can insert AXI4-to-AXI3 converters
with `AXI4_INTERFACE=1`. It generates 450 MHz AXI and 100 MHz reference/APB
clocks from a 250 MHz input and exposes a ready signal and reset/status bus.
The current test instantiates `cl_hbm` directly, so it does not test that wrapper.

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

The runner suppresses the identified `tCHmax`, IEEE1500 `tWRSTL`, and IEEE1500
`tHF` warning lines from `run.log` and failure excerpts. It preserves the full
simulator output in `<case>/run.raw.log` and records the suppressed count in
`summary.json`. Other warnings and errors remain visible. Result classification
uses the raw output and simulator exit status. Filtering does not disable model
checks or resolve the underlying timing warnings; the functional pass does not
establish timing-model accuracy. Compiler messages about unused VIP interfaces
also remain visible.

## Latency probe

[`f2_hbm_latency_tb.sv`](f2_hbm_latency_tb.sv) measures timing on the same
model. It reuses the prepared sources and the same runner:

```sh
make test-f2-hbm-latency-cae F2_HBM_ARGS="--host YOUR_NETID@best-linux.cae.wisc.edu"
```

Every burst is 16 beats. `RREADY` and `BREADY` stay high so the numbers reflect
the memory, not the testbench. Each record in `latency/latency.csv` holds cycle
stamps for request valid, address acceptance, first read beat (or last write
beat) and completion, in 450 MHz AXI cycles counted from reset deassertion.

| Phase | Traffic | Answers |
| --- | --- | --- |
| 1 idle | Each port alone, one read at a time, to its own channel, PC 0 and PC 16; three reads per address | Idle and page-hit latency; switch distance |
| 2 stride | Port 0 alternates two addresses `2^k` bytes apart, k = 5..28 | Which address bits cause row conflicts |
| 3 depth | Port 0 sequential reads with 1 to 64 outstanding | Latency and bandwidth versus queue depth |
| 4 random | Port 0, 16 outstanding, random within 64 MiB | Latency under page misses |
| 5 all_ports | All 32 ports stream to their own channels | Aggregate bandwidth, tail latency, refresh stalls |
| 6 mixed | Port 0 alternating reads and writes; after they drain, writes only | Read/write turnaround and write latency |

Each phase must log its exact expected record count or the run fails with
`HBM_LATENCY_MISSING`. The runner also runs two expected-failure cases: phase 1
with its traffic withheld (`+DROP_PHASE=1`) and omitted reset. Plusargs:
`+PHASES=<mask>` selects phases (bit 0 is phase 1), `+ALL_PORTS_CYCLES=<n>` sets
the phase 5 length (default 9000 cycles, several refresh intervals) and
`+WATCHDOG_US=<n>` sets the simulation-time limit (default 3000 µs).

After a passing run the runner writes `latency/latency_summary.json` with
`scripts/f2_hbm_latency.py`: queue, first-beat and completion percentiles per
phase, the stride table, bandwidth, per-phase completion order (reads, writes
and both together, per port), and a calibration block for the software team's
HBM counter study. The calibration's hit and row-conflict cycles both use reads
within the port's own pseudo-channel; reads through the switch are reported as
`switched_hit_cycles`.

WDATA and WLAST are a function of the burst ID and beat and stay stable while
WVALID waits for WREADY; an assertion checks this on every port. Rerun the analysis on a retrieved CSV with
`python3 scripts/f2_hbm_latency.py PATH/latency.csv --output summary.json`.

These are measurements of AMD's simulation model in this configuration. They
are not hardware measurements, and the model's internal timing is encrypted, so
the probe can only observe it at the AXI ports.

Run Python failure-classification checks with `make test-tooling`.
