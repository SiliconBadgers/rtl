#!/usr/bin/env python3
"""Check or format integration sources listed in style.json; never touch vendor code."""

import argparse
import difflib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fix", action="store_true")
args = parser.parse_args()
config = json.loads((ROOT / "style.json").read_text())
files = set()
for pattern in config["systemverilog"]:
    matches = list(ROOT.glob(pattern))
    if not matches:
        raise SystemExit(f"No sources match {pattern}; initialize components or fix style.json")
    files.update(matches)
files = sorted(files)
failed = False
for path in files:
    formatted = subprocess.check_output(
        [
            "verible-verilog-format",
            "--column_limit=100",
            "--indentation_spaces=2",
            "--wrap_spaces=2",
            str(path),
        ],
        text=True,
    )
    original = path.read_text()
    if formatted != original:
        if args.fix:
            path.write_text(formatted)
        else:
            print(
                "".join(
                    difflib.unified_diff(
                        original.splitlines(True),
                        formatted.splitlines(True),
                        fromfile=str(path),
                        tofile="formatted",
                    )
                )
            )
            failed = True
subprocess.run(["verible-verilog-lint", "--ruleset=default", *map(str, files)], check=True)
python_paths = config.get("python", [])
if python_paths:
    subprocess.run(
        ["ruff", "check", *(["--fix"] if args.fix else []), *python_paths], cwd=ROOT, check=True
    )
    subprocess.run(
        ["ruff", "format", *([] if args.fix else ["--check"]), *python_paths], cwd=ROOT, check=True
    )
if failed:
    raise SystemExit("Formatting differs; run make format")
print(f"Style checks passed for {len(files)} SystemVerilog sources")
