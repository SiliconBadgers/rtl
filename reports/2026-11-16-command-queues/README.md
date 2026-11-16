# Command queue regression on CAE

Tested commit: `1086b0ba0b79faa6849c63a9a50a715d6fe1ac16`.
The subsequent evidence commit changes only this report and its logs.

The run used CAE host `linux-2001` through one SSH ControlMaster connection to
`ztaylor6@best-linux.cae.wisc.edu`. Compilation and simulation used
`synopsys/vcs-mx/2026.03`, `synopsys-run`, and the checked-in `scripts/vcs.py`:
VCS compiler and runtime `Y-2026.03_Full64`. There are no external RTL dependencies.

## Reproduction

From a checkout of the tested commit, on CAE:

```sh
module load synopsys/vcs-mx/2026.03
export VCS_LAUNCHER=synopsys-run
python3 scripts/command_queues.py --seeds 1 7 42
```

The [test guide](../../tb/control/README.md) describes configurations, limits,
negative tests, and output paths. The [machine-readable summary](logs/summary.json)
records source hashes, every command, elapsed times, raw exit codes, and observed
counters. Its absolute paths identify the remote run; corresponding logs are
preserved under [logs/](logs/) with the same configuration and file names.

## Results

Eight configurations were planned and compiled successfully. All 24 planned
simulations started and passed their expected outcome: 17 positive simulations
and seven expected failures; zero unexpected failures and zero skipped tests.
Total runner elapsed time was 66.947 seconds, including compilation and the
10-second deliberate timeout. Compiler logs contain no warnings or errors.

| Checks | Observed counts |
| --- | --- |
| Standalone queues, depths 1/3/4, seeds 1/7/42 | 9,569 checked cycles; 4,100 accepted, 4,076 issued, 24 cancelled by active reset |
| Queue scenarios | 1,309 simultaneous push/pop cycles; 2,440 full-pop cycles; 2,160 stalled offers; 719 retained offers with dependencies low |
| Scoreboards, legacy and custom mappings | 7,705 queue-level dependency decisions, each comparing both slots; 5,507 counter-value checks; 20 wraps |
| Scoreboard increment observations | 2,617 zero, 89 one, and 45 two increments sampled across counters |
| Wrappers, legacy and custom mappings, seeds 1/7/42 | 53,100 queue-output or counter checks; 2,734 accepted, 2,713 issued, 21 cancelled by active reset; 2,758 stalled offers |

Each positive test fails if required scenarios are absent. Six negative
simulations exited 3 with their required diagnostic: missing active reset,
missing backpressure, wrong reference result, illegal increment, unknown
increment, and invalid mapping. The deliberate hang reached `TIMEOUT_ARMED`
and exited 124 through the wall-clock limiter. These seven passes count error
detection, not successful hardware transactions.

The first run at `da5842019be746e18c34300a23d6ef00ed3369c5` completed 24
simulations with five wrapper drain failures. Its reference checks reported no
output mismatches. Random duplicate-counter targets could have disjoint
eligibility windows, and lockstep drain increments preserved counter offsets.
The tested revision constrains duplicate random targets and steers each head's
counters independently during drain. The complete suite was rerun after that
change; no RTL was changed.

[Style checks](style.log) passed using Verible `v0.0-3946-g851d3ff4`, Ruff
`0.16.6`, and uv `0.12.23`. All 25 existing [tooling tests](tooling.log) passed.
`git diff --check` also passed.

Code and functional coverage were not measured. Small counter widths exercise
wrap and comparison boundaries; these runs do not cover every legal parameter
combination. Formal verification, synthesis, timing, and CDC/reset-domain
analysis were not run. The wrapper is tested without a router or engine datapath.

AI assistance: Codex; exact model ID unavailable.
