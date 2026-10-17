#!/usr/bin/env python3
"""Run a command with a wall-clock limit on macOS or Linux; retain its exit status."""

import argparse
import math
import os
import signal
import subprocess
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--elapsed-file", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("supply a command and a positive finite timeout")
    start = time.monotonic()
    try:
        with subprocess.Popen(command, start_new_session=True) as process:
            try:
                code = process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                # Kill the command's process group, including simulator children.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                print(f"Timed out after {args.timeout:g} seconds", flush=True)
                return 124
            return code if code >= 0 else 128 - code
    except OSError as error:
        print(f"Cannot start {command[0]}: {error}", flush=True)
        return 127
    finally:
        args.elapsed_file.write_text(f"{time.monotonic() - start:.3f}\n")


if __name__ == "__main__":
    raise SystemExit(main())
