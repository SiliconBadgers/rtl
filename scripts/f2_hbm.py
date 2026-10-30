#!/usr/bin/env python3
"""Stage AWS F2 HBM models and run their functional regression locally or over SSH."""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

import f2_hbm_latency

ROOT = Path(__file__).resolve().parents[1]
TEST = ROOT / "tb/memory/f2_hbm"
PINS = json.loads((TEST / "dependencies.json").read_text())
AWS = ROOT / "third_party/aws-fpga"
IP = AWS / "hdk/common/ip"
VIVADO = ROOT / "third_party/vivado-2024.2"
HBM = IP / "cl_ip/cl_ip.gen/sources_1/ip/cl_hbm"
STATIC = IP / "cl_ip/cl_ip.ip_user_files/ipstatic"
VENDOR_DIRS = [
    "data/xilinx_vip",
    "data/ip/xpm",
    "data/verilog/src/unisims",
    "data/secureip/hbm_two_stack_intf",
]
BENCHES = {
    "functional": {
        "top": "f2_hbm_tb",
        "source": "f2_hbm_tb.sv",
        "output": "build/f2_hbm",
        "marker": "F2_HBM_PASS ",
        "cases": {
            "read_write": ([], None),
            "bad_data": (["+CORRUPT_EXPECTED=1"], "HBM_DATA_MISMATCH"),
            "missing_reset": (["+SKIP_RESET=1"], "HBM_RESET_REQUIRED"),
            "missing_backpressure": (["+SKIP_BACKPRESSURE=1"], "HBM_BACKPRESSURE_REQUIRED"),
        },
    },
    "latency": {
        "top": "f2_hbm_latency_tb",
        "source": "f2_hbm_latency_tb.sv",
        "output": "build/f2_hbm_latency",
        "marker": "F2_HBM_LATENCY_DONE ",
        "cases": {
            "latency": ([], None),
            # Idle (phase 1) traffic is withheld, so its record count must fail.
            "missing_phase": (["+DROP_PHASE=1", "+PHASES=1"], "HBM_LATENCY_MISSING"),
            "missing_reset": (["+SKIP_RESET=1"], "HBM_RESET_REQUIRED"),
        },
    },
}
CASES = BENCHES["functional"]["cases"]
TIMING_WARNING = re.compile(
    r"(?:HBM\[CH_[A-H]\]\s*:\s*Warning tCHmax violation at \d+(?:\.\d+)? ns\. "
    r"tCH is \d+(?:\.\d+)? ns|IEEE1500\s*:\s*Warning "
    r"(?:tWRSTL violation on WRST_n|tHF violation on UpdateWR)\s+at \d+(?:\.\d+)? ns)[ \t]*"
)


def run(command, **kwargs):
    print("$ " + shlex.join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checkout(url, revision, destination):
    if not (destination / ".git").exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "init", destination])
        run(["git", "-C", destination, "remote", "add", "origin", url])
    current = subprocess.run(
        ["git", "-C", str(destination), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    if current.stdout.strip() != revision:
        # Avoid fetching synthesis products; only the HBM simulation pointers are materialized below.
        env = dict(os.environ, GIT_LFS_SKIP_SMUDGE="1")
        run(["git", "-C", destination, "fetch", "--depth", "1", "origin", revision], env=env)
        run(["git", "-C", destination, "checkout", "--detach", revision], env=env)


def materialize(path):
    content = path.read_bytes()
    if not content.startswith(b"version https://git-lfs.github.com/spec/v1\n"):
        return
    match = re.search(rb"oid sha256:([0-9a-f]{64})\nsize ([0-9]+)", content)
    if not match:
        raise ValueError(f"Invalid Git LFS pointer: {path}")
    relative = path.relative_to(IP).as_posix()
    url = (
        "https://media.githubusercontent.com/media/aws/aws-fpga-resources/"
        f"{PINS['resources_revision']}/{relative}"
    )
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    if len(data) != int(match[2]) or hashlib.sha256(data).hexdigest() != match[1].decode():
        raise ValueError(f"Git LFS hash/size mismatch: {relative}")
    temporary = path.with_name(path.name + ".download")
    temporary.write_bytes(data)
    temporary.replace(path)


def prepare(source):
    source = source.expanduser().resolve()
    for relative in [*VENDOR_DIRS, "data/verilog/src/glbl.v"]:
        if not (source / relative).exists():
            raise ValueError(f"Missing Vivado 2024.2 source: {source / relative}")
    checkout(PINS["aws_url"], PINS["aws_revision"], AWS)
    checkout(PINS["resources_url"], PINS["resources_revision"], IP)
    paths = [
        HBM / "sim/cl_hbm.sv",
        HBM / "hdl/rtl/hbm_v1_0_16.sv",
        HBM / "verif/model/hbm_model.sv",
        STATIC / "hdl/hbm_v1_0_vl_rfs.sv",
        STATIC / "verif/model/HBM_vcs.vp",
        STATIC / "verif/model/hbm_parameter.v",
    ]
    for path in paths:
        materialize(path)
    for relative in VENDOR_DIRS:
        print(f"Staging {relative}", flush=True)
        shutil.copytree(source / relative, VIVADO / relative, dirs_exist_ok=True)
    target = VIVADO / "data/verilog/src/glbl.v"
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "data/verilog/src/glbl.v", target)
    paths += [p for p in (VIVADO / "data").rglob("*") if p.is_file()]
    paths += list((HBM / "hdl/rtl").glob("*.mem")) + [HBM / "hdl/rtl/defines.vh"]
    manifest = {
        "dependencies": PINS,
        "files": {str(p.relative_to(ROOT)): digest(p) for p in sorted(paths)},
    }
    (VIVADO / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared {len(paths)} files, {sum(p.stat().st_size for p in paths):,} bytes")


def verify_assets():
    manifest = json.loads((VIVADO / "manifest.json").read_text())
    if manifest["dependencies"] != PINS:
        raise ValueError("Dependency pins changed; rerun prepare")
    for relative, expected in manifest["files"].items():
        if digest(ROOT / relative) != expected:
            raise ValueError(f"Staged source changed: {relative}; rerun prepare")
    return manifest


def sources(bench="functional"):
    vip = VIVADO / "data/xilinx_vip/hdl"
    names = [
        "axi4stream_vip_axi4streampc.sv",
        "axi_vip_axi4pc.sv",
        "xil_common_vip_pkg.sv",
        "axi4stream_vip_pkg.sv",
        "axi_vip_pkg.sv",
        "axi4stream_vip_if.sv",
        "axi_vip_if.sv",
        "clk_vip_if.sv",
        "rst_vip_if.sv",
    ]
    secure = VIVADO / "data/secureip/hbm_two_stack_intf"
    return [
        *[vip / name for name in names],
        VIVADO / "data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv",
        VIVADO / "data/ip/xpm/xpm_memory/hdl/xpm_memory.sv",
        secure / "hbm_two_stack_intf_001.sv",
        secure / "hbm_two_stack_intf_002.svp",
        HBM / "hdl/rtl/hbm_v1_0_16.sv",
        STATIC / "hdl/hbm_v1_0_vl_rfs.sv",
        HBM / "verif/model/hbm_model.sv",
        HBM / "sim/cl_hbm.sv",
        VIVADO / "data/verilog/src/glbl.v",
        TEST / BENCHES[bench]["source"],
    ]


def summarize_latency(case):
    """Summarize latency.csv next to the run log; a missing or empty file fails the case."""
    path = case / "latency.csv"
    if not path.is_file():
        raise ValueError(f"Latency case passed without {path}")
    result = f2_hbm_latency.summarize(f2_hbm_latency.load(path))
    (case / "latency_summary.json").write_text(json.dumps(result, indent=2) + "\n")
    return {"records": result["records"], "summary": "latency_summary.json"}


def classify(code, output, expected_failure, marker="F2_HBM_PASS "):
    if expected_failure:
        return code not in (0, 124) and expected_failure in output
    return (
        code == 0
        and marker in output
        and not re.search(r"\b(?:error|fatal)(?:-\[[^]]+\])?\s*:", output, re.IGNORECASE)
    )


def filter_timing_warnings(content):
    """Remove only the three identified vendor timing-warning line formats."""
    kept = []
    suppressed = 0
    for line in content.splitlines(keepends=True):
        if TIMING_WARNING.fullmatch(line.rstrip("\r\n")):
            suppressed += 1
        else:
            kept.append(line)
    return "".join(kept), suppressed


def simulate(args):
    verify_assets()
    bench = BENCHES[args.bench]
    output = (args.output or ROOT / bench["output"]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    summary = {
        "dependencies": PINS,
        "vcs_baseline": "Y-2026.03_Full64",
        "bench": args.bench,
        "seed": args.seed,
        "host": os.uname().nodename,
        "cases": [],
        "coverage": "Not measured",
        "asset_manifest_sha256": digest(VIVADO / "manifest.json"),
        "inputs": {
            str(p.relative_to(ROOT)): digest(p)
            for p in [
                TEST / bench["source"],
                Path(__file__),
                ROOT / "scripts/vcs.py",
                ROOT / "scripts/f2_hbm_latency.py",
            ]
        },
    }
    start = time.monotonic()
    try:
        command = [
            sys.executable,
            ROOT / "scripts/vcs.py",
            "--timeout",
            args.timeout,
            "compile",
            "-timescale=1ps/1ps",
            "+define+VCS",
            "+libext+.v",
            "-y",
            VIVADO / "data/verilog/src/unisims",
            "+librescan",
            "+incdir+" + str(VIVADO / "data/xilinx_vip/include"),
            "+incdir+" + str(HBM / "hdl/rtl"),
            "+incdir+" + str(STATIC / "verif/model"),
            "-top",
            bench["top"],
            "-top",
            "glbl",
            "-o",
            output / "simv",
            *sources(args.bench),
        ]
        with (output / "compile.log").open("w") as log:
            run(command, cwd=output, stdout=log, stderr=subprocess.STDOUT)
        for name, (flags, expected) in bench["cases"].items():
            case = output / name
            case.mkdir(exist_ok=True)
            for path in (HBM / "hdl/rtl").glob("*.mem"):
                shutil.copy2(path, case / path.name)
            before = time.monotonic()
            command = [
                sys.executable,
                ROOT / "scripts/vcs.py",
                "--timeout",
                str(args.timeout),
                "run",
                output / "simv",
                f"+SEED={args.seed}",
                *flags,
            ]
            with (case / "run.raw.log").open("w") as log:
                result = subprocess.run(
                    list(map(str, command)),
                    cwd=case,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=False,
                )
            content = (case / "run.raw.log").read_text(errors="replace")
            filtered, suppressed = filter_timing_warnings(content)
            (case / "run.log").write_text(filtered)
            passed = classify(result.returncode, content, expected, bench["marker"])
            counts = re.search(re.escape(bench["marker"]) + r"(.*)", content)
            record = {
                "name": name,
                "passed": passed,
                "exit_code": result.returncode,
                "expected_failure": expected,
                "elapsed_seconds": time.monotonic() - before,
                "observed": counts[1] if counts else None,
                "model_timing_warnings": len(re.findall(r"Warning.*violation", content)),
                "suppressed_timing_warnings": suppressed,
            }
            if passed and args.bench == "latency" and not expected:
                record["latency"] = summarize_latency(case)
            summary["cases"].append(record)
            print(json.dumps(record), flush=True)
            if not passed:
                print(filtered[-6000:], flush=True)
                raise ValueError(f"HBM case failed: {name}; see {case / 'run.log'}")
    finally:
        summary["elapsed_seconds"] = time.monotonic() - start
        summary["passed"] = len(summary["cases"]) == len(bench["cases"]) and all(
            case["passed"] for case in summary["cases"]
        )
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")


def remote(args):
    if not args.host:
        raise ValueError("Supply --host NETID@best-linux.cae.wisc.edu or set RTL_CAE_HOST")
    verify_assets()
    with tempfile.TemporaryDirectory(prefix="rtl-hbm-ssh-") as temporary:
        socket = str(Path(temporary) / "control")
        ssh = [
            "ssh",
            "-S",
            socket,
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=30",
            "-o",
            "ServerAliveInterval=30",
            "-o",
            "ServerAliveCountMax=3",
        ]
        run([*ssh, "-M", "-f", "-N", args.host])
        # If the master dies, fail instead of opening a new load-balanced connection.
        ssh += ["-o", "ControlMaster=no", "-o", "ProxyCommand=false"]
        try:
            result = run(
                [*ssh, args.host, "mktemp -d /tmp/sibadgers-f2-hbm.XXXXXXXX"],
                capture_output=True,
                text=True,
            )
            directory = result.stdout.strip()
            if not re.fullmatch(r"/tmp/sibadgers-f2-hbm\.[A-Za-z0-9]+", directory):
                raise ValueError(f"Unexpected remote scratch path: {directory!r}")
            print(f"Remote scratch: {args.host}:{directory}", flush=True)
            run(
                [
                    "rsync",
                    "-az",
                    "--exclude=.git",
                    "--exclude=.venv",
                    "--exclude=build",
                    "--exclude=__pycache__",
                    "--exclude=.ruff_cache",
                    "-e",
                    shlex.join(ssh),
                    str(ROOT) + "/",
                    f"{args.host}:{directory}/",
                ]
            )
            command = shlex.join(
                [
                    "python3",
                    "scripts/f2_hbm.py",
                    "simulate",
                    "--bench",
                    args.bench,
                    "--seed",
                    str(args.seed),
                    "--timeout",
                    str(args.timeout),
                ]
            )
            body = (
                "set -eo pipefail\n"
                "export LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}\n"
                "export LIBRARY_PATH=${LIBRARY_PATH:-}\n"
                "if [ -f /etc/profile.d/modules.sh ]; then . /etc/profile.d/modules.sh; fi\n"
                "module load synopsys/vcs-mx/2026.03\n"
                f"cd {shlex.quote(directory)}\n{command}\n"
            )
            result = subprocess.run(
                [*ssh, args.host, "bash -lc " + shlex.quote(body)],
                check=False,
            )
            bench = BENCHES[args.bench]
            destination = (args.output or ROOT / bench["output"]).resolve() / Path(directory).name
            destination.mkdir(parents=True, exist_ok=True)
            run(
                [
                    "rsync",
                    "-az",
                    "--exclude=csrc/",
                    "--exclude=simv.daidir/",
                    "--include=*/",
                    "--include=*.log",
                    "--include=*.json",
                    "--include=*.csv",
                    "--exclude=*",
                    "-e",
                    shlex.join(ssh),
                    f"{args.host}:{directory}/{bench['output']}/",
                    str(destination) + "/",
                ]
            )
            print(f"Local results: {destination}", flush=True)
            (destination / "remote.json").write_text(
                json.dumps(
                    {
                        "host": args.host,
                        "scratch": directory,
                        "exit_code": result.returncode,
                        "git_revision": subprocess.check_output(
                            ["git", "rev-parse", "HEAD"],
                            cwd=ROOT,
                            text=True,
                        ).strip(),
                    },
                    indent=2,
                )
                + "\n"
            )
            if result.returncode:
                raise subprocess.CalledProcessError(result.returncode, command)
        finally:
            subprocess.run([*ssh, "-O", "exit", args.host], check=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    stage = sub.add_parser("prepare", help="Clone pinned AWS sources and stage local Vivado files")
    stage.add_argument(
        "--vivado",
        type=Path,
        default=Path(os.environ.get("XILINX_VIVADO", "~/opt/Xilinx/Vivado/2024.2")),
    )
    for action in ("simulate", "remote"):
        run_parser = sub.add_parser(action)
        run_parser.add_argument("--seed", type=int, default=1)
        run_parser.add_argument("--timeout", type=int, default=1200)
        run_parser.add_argument("--bench", choices=sorted(BENCHES), default="functional")
        run_parser.add_argument(
            "--output",
            type=Path,
            help="Results parent (default build/f2_hbm or build/f2_hbm_latency)",
        )
        if action == "remote":
            run_parser.add_argument("--host", default=os.environ.get("RTL_CAE_HOST"))
    args = parser.parse_args()
    if args.action != "prepare" and (args.timeout <= 0 or not 0 <= args.seed < 2**32):
        parser.error("--timeout must be positive and --seed must fit an unsigned 32-bit value")
    try:
        if args.action == "prepare":
            prepare(args.vivado)
        elif args.action == "simulate":
            simulate(args)
        else:
            remote(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
