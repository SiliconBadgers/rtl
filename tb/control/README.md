# Command queue and scoreboard regressions

Run the local block tests from the repository root with Synopsys VCS
Y-2026.03_Full64. The tests cover the
[command queue and scoreboard contract](../../docs/control/command-scoreboard.md);
they do not exercise the command router or an engine datapath.

On CAE:

```sh
module load synopsys/vcs-mx/2026.03
export VCS_LAUNCHER=synopsys-run
python3 scripts/command_queues.py --seeds 1 7 42
```

The runner uses only Python's standard library and the checked-in
[`scripts/vcs.py`](../../scripts/vcs.py) helper. No external RTL dependency is
required. On a workstation with the [project tools](../../SETUP.md), the equivalent
entry point is `make test-command-queues`. Pass options through
`COMMAND_QUEUES_ARGS`, for example `make test-command-queues COMMAND_QUEUES_ARGS="--seeds 7"`.
Check out the tested revision recorded in the run report before reproducing it.
When staging sources to CAE, pass `--revision <commit>` to retain that identity
without a remote Git checkout; the runner also records source SHA-256 hashes.

## Test configurations

| Testbench | Configurations | Checks |
| --- | --- | --- |
| `command_queue_tb` | Depths 1, 3, 4; payload width 16; counter width 4 | FIFO order and targets, empty/full behavior, pointer wrap, simultaneous transfers, dependency stalls, retained offers, active reset, seeded traffic |
| `shared_scoreboard_tb` | Default mapping and custom 4-queue/2-counter mapping | Exhaustive small-width comparisons, zero target, half-range boundary, increments 0/1/2, counter wrap, registered progress, reset |
| `command_queues_tb` | Default mapping and custom 4-queue/2-counter mapping | Queue isolation, two dependencies, head blocking, retained issue across counter wrap, active reset |

The default run plans eight compiled configurations and 24 simulations: 17
positive simulations and seven expected failures. The latter check illegal and
unknown increments, invalid mapping, missing reset and backpressure scenarios,
wrong-result detection, and the wall-clock timeout. An expected failure passes
only when its log contains the required diagnostic and the process exits
nonzero; the timeout additionally requires exit code 124 and a marker proving
the testbench reached its deliberate hang. Positive runs require both exit code
zero and a testbench result line.

## Results and failures

Results go to `build/command_queues/summary.json`, with `version.log` and per-
configuration compilation and simulation logs beside it. Use `--output <path>`
to keep separate runs. The summary records commands, source hashes, parameters,
seeds, elapsed times, raw exit codes, and testbench counters. Simulation counts
exclude configurations that failed compilation; skipped simulations are reported
separately. An expected-failure pass verifies error detection, not a normal
hardware transaction. Counters describe observed testbench checks and scenarios,
not measured code or functional coverage.

Normal simulations time out after 120 seconds, compilation after 900 seconds,
and the deliberate timeout test after 10 seconds. Adjust these limits with
`--timeout`, `--compile-timeout`, and `--negative-timeout`. The runner returns the
first unexpected subprocess failure code, or 1 for a missing result/diagnostic.
Inspect the failing test's log before changing a timeout. Formal verification,
synthesis, timing, and CDC/reset-domain analysis are outside this regression.
