#!/usr/bin/env python3
"""Run the pinned VCS compiler and simulator directly or through the CAE launcher."""

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BASELINE = "Y-2026.03_Full64"
TIMEOUT_RUNNER = Path(__file__).with_name("run_with_timeout.py")


def launcher():
    configured = os.environ.get("VCS_LAUNCHER")
    if configured is not None:
        prefix = shlex.split(configured)
    else:
        prefix = ["synopsys-run"] if shutil.which("synopsys-run") else []
    required = prefix[0] if prefix else "vcs"
    if not shutil.which(required):
        raise ValueError(
            f"Missing {required}. On CAE run: module load synopsys/vcs-mx/2026.03. "
            "VCS is required; there is no alternate simulator fallback."
        )
    return prefix


def timed_command(command, timeout, elapsed):
    return [
        sys.executable,
        str(TIMEOUT_RUNNER),
        "--timeout",
        str(timeout),
        "--elapsed-file",
        str(elapsed),
        "--",
        *command,
    ]


def check_version(prefix):
    with tempfile.TemporaryDirectory(prefix="vcs-version-") as directory:
        result = subprocess.run(
            timed_command([*prefix, "vcs", "-full64", "-ID"], 30, Path(directory) / "elapsed"),
            capture_output=True,
            text=True,
            check=False,
        )
    match = re.search(r"Compiler version\s*=\s*VCS\s+(\S+)", result.stdout)
    if result.returncode or not match:
        raise ValueError(f"VCS version check failed:\n{result.stdout}{result.stderr}")
    if match[1] != BASELINE:
        raise ValueError(
            f"Unsupported VCS version {match[1]}; this regression pins {BASELINE}. "
            "Load synopsys/vcs-mx/2026.03 on CAE. Validate tool upgrades before changing the pin."
        )
    return f"VCS {match[1]}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument("--elapsed-file", type=Path)
    parser.add_argument("action", choices=["check", "compile", "run"])
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    start = time.monotonic()
    try:
        prefix = launcher()
        if args.action in ("check", "compile"):
            print(check_version(prefix), flush=True)
        if args.action == "check":
            if args.arguments:
                parser.error("check takes no additional arguments")
            return 0
        if not args.arguments:
            parser.error("supply compiler arguments or a simulator executable")
        if args.action == "compile":
            command = [
                *prefix,
                "vcs",
                "-full64",
                "-sverilog",
                "-timescale=1ns/1ps",
                "-assert",
                "svaext",
                *args.arguments,
            ]
        else:
            binary = Path(args.arguments[0]).resolve()
            if not binary.is_file():
                parser.error(f"Simulator executable is missing: {binary}")
            command = [*prefix, str(binary), "-exitstatus", *args.arguments[1:]]
        print("$ " + shlex.join(command), flush=True)
        with tempfile.TemporaryDirectory(prefix="vcs-time-") as directory:
            elapsed = args.elapsed_file or Path(directory) / "elapsed"
            return subprocess.call(timed_command(command, args.timeout, elapsed))
    except ValueError as error:
        parser.error(str(error))
    finally:
        if args.elapsed_file:
            args.elapsed_file.write_text(f"{time.monotonic() - start:.3f}\n")


if __name__ == "__main__":
    raise SystemExit(main())
