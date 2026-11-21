#!/usr/bin/env python3
"""Compile and run command queue/scoreboard regressions with the pinned VCS helper."""

import argparse
import hashlib
import json
import math
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VCS = ROOT / "scripts/vcs.py"
RTL = [
    ROOT / "rtl/control" / f"{name}.sv"
    for name in ("command_queue", "shared_scoreboard", "command_queues")
]


def configurations(seeds):
    configs = []
    for depth in (1, 3, 4):
        runs = [(f"seed-{seed}", [f"+seed={seed}"], None) for seed in seeds]
        if depth == 3:
            runs += [
                ("missing-reset", ["+missing_reset=1"], "missing reset prerequisite"),
                (
                    "missing-backpressure",
                    ["+missing_backpressure=1"],
                    "missing backpressure prerequisite",
                ),
                ("wrong-result", ["+wrong_result=1"], "queue data mismatch"),
                ("timeout", ["+timeout=1"], "TIMEOUT_ARMED"),
            ]
        configs.append((f"queue-depth-{depth}", "command_queue_tb", {"QueueDepth": depth}, runs))
    for custom in (0, 1):
        runs = [("exhaustive", [], None)]
        if custom == 0:
            runs += [
                ("illegal-increment", ["+illegal_increment=1"], "Illegal milestone increment"),
                ("unknown-increment", ["+unknown_increment=1"], "Illegal milestone increment"),
            ]
        configs.append(
            (f"scoreboard-map-{custom}", "shared_scoreboard_tb", {"CustomMapping": custom}, runs)
        )
        configs.append(
            (
                f"wrapper-map-{custom}",
                "command_queues_tb",
                {"CustomMapping": custom},
                [(f"seed-{seed}", [f"+seed={seed}"], None) for seed in seeds],
            )
        )
    configs.append(
        (
            "scoreboard-invalid-map",
            "shared_scoreboard_tb",
            {"InvalidMapping": 1},
            [("invalid-map", [], "Set valid WaitCounter0/1 indices")],
        )
    )
    return configs


def execute(command, directory, log):
    start = time.monotonic()
    with log.open("w") as stream:
        stream.write("$ " + shlex.join(command) + "\n")
        stream.flush()
        result = subprocess.run(
            command, cwd=directory, stdout=stream, stderr=subprocess.STDOUT, check=False
        )
    return {
        "command": command,
        "exit_code": result.returncode,
        "elapsed_seconds": round(time.monotonic() - start, 3),
        "log": str(log),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Source commit when running a staged tree without Git")
    parser.add_argument("--seeds", type=int, nargs="+", default=[1, 7, 42])
    parser.add_argument("--output", type=Path, default=ROOT / "build/command_queues")
    parser.add_argument(
        "--timeout", type=float, default=120, help="Wall-clock limit for each normal simulation"
    )
    parser.add_argument("--compile-timeout", type=float, default=900)
    parser.add_argument("--negative-timeout", type=float, default=10)
    args = parser.parse_args()
    for value in (args.timeout, args.compile_timeout, args.negative_timeout):
        if not math.isfinite(value) or value <= 0:
            parser.error("timeouts must be positive finite numbers")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    configs = configurations(args.seeds)
    sources = RTL + [
        ROOT / "tb/control" / f"{top}.sv"
        for top in ("command_queue_tb", "shared_scoreboard_tb", "command_queues_tb")
    ]
    sources += [Path(__file__).resolve(), VCS, ROOT / "scripts/run_with_timeout.py"]
    summary = {
        "tool": "VCS Y-2026.03_Full64",
        "seeds": args.seeds,
        "configurations_planned": len(configs),
        "simulations_planned": sum(len(runs) for _, _, _, runs in configs),
        "configurations": [],
        "simulations": [],
        "coverage": "Not measured",
    }
    start = time.monotonic()
    failure = 0
    try:
        revision = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, capture_output=True, check=False
        )
        summary["git_revision"] = args.revision or (
            revision.stdout.strip() if revision.returncode == 0 else None
        )
        summary["source_sha256"] = {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sources
        }
        preflight = execute([sys.executable, str(VCS), "check"], output, output / "version.log")
        summary["preflight"] = preflight
        if preflight["exit_code"]:
            failure = preflight["exit_code"]
            return failure
        for name, top, parameters, runs in configs:
            directory = output / name
            directory.mkdir(parents=True, exist_ok=True)
            binary = directory / "simv"
            command = [
                sys.executable,
                str(VCS),
                "--timeout",
                str(args.compile_timeout),
                "compile",
                "-top",
                top,
                "-o",
                str(binary),
            ]
            for parameter, value in parameters.items():
                command += [f"-pvalue+{top}.{parameter}={value}"]
            command += [str(path) for path in RTL]
            command += [str(ROOT / "tb/control" / f"{top}.sv")]
            compilation = execute(command, directory, directory / "compile.log")
            compilation.update(name=name, top=top, parameters=parameters)
            summary["configurations"].append(compilation)
            if compilation["exit_code"]:
                failure = failure or compilation["exit_code"]
                print(f"FAIL {name}: compilation (exit {compilation['exit_code']})", flush=True)
                continue
            for run_name, plusargs, expected in runs:
                timeout = args.negative_timeout if run_name == "timeout" else args.timeout
                command = [
                    sys.executable,
                    str(VCS),
                    "--timeout",
                    str(timeout),
                    "run",
                    str(binary),
                    *plusargs,
                ]
                result = execute(command, directory, directory / f"{run_name}.log")
                text = Path(result["log"]).read_text()
                markers = [
                    line for line in text.splitlines() if line.startswith(("RESULT ", "SUMMARY "))
                ]
                if expected:
                    passed = result["exit_code"] != 0 and expected in text
                    if run_name == "timeout":
                        passed = passed and result["exit_code"] == 124 and "Timed out after" in text
                    else:
                        passed = passed and result["exit_code"] != 124
                else:
                    passed = result["exit_code"] == 0 and len(markers) == 1
                counters = {}
                if markers:
                    counters = {
                        key: int(value) for key, value in re.findall(r"\b(\w+)=(\d+)\b", markers[0])
                    }
                result.update(
                    configuration=name,
                    name=run_name,
                    expected_failure=expected,
                    passed=passed,
                    counters=counters,
                    result_lines=markers,
                )
                summary["simulations"].append(result)
                if not passed:
                    failure = failure or result["exit_code"] or 1
                print(
                    f"{'PASS' if passed else 'FAIL'} {name}/{run_name} "
                    f"(exit {result['exit_code']})",
                    flush=True,
                )
        return failure
    except OSError as error:
        failure = 127
        summary["error"] = str(error)
        print(str(error), file=sys.stderr)
        return failure
    finally:
        simulations = summary["simulations"]
        summary.update(
            configurations_compiled=sum(c["exit_code"] == 0 for c in summary["configurations"]),
            configurations_failed=sum(c["exit_code"] != 0 for c in summary["configurations"]),
            simulations_started=len(simulations),
            simulations_passed=sum(r["passed"] for r in simulations),
            simulations_failed=sum(not r["passed"] for r in simulations),
            simulations_skipped=summary["simulations_planned"] - len(simulations),
            expected_failures_verified=sum(
                r["passed"] and r["expected_failure"] is not None for r in simulations
            ),
            exit_code=failure,
            elapsed_seconds=round(time.monotonic() - start, 3),
        )
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"Summary: {output / 'summary.json'}", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
