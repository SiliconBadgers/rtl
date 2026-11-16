#!/usr/bin/env python3
"""Summarize latency.csv from the F2 HBM latency probe (tb/memory/f2_hbm/f2_hbm_latency_tb.sv).

All times are 450 MHz AXI cycles. For a read, `first` is address acceptance to
the first data beat and `total` is acceptance to RLAST. For a write, `first` is
address acceptance to the last data beat and `total` is acceptance to the B
response. `queue` is the time a request waited for ARREADY/AWREADY.

The calibration block fits the two-level latency model used by the software
team's HBM counter study: a page-hit latency, a slower row-conflict latency and
an occasional stall (refresh or bank busy) on top. Stalls are measured only on
reads issued one at a time, so queueing behind other requests does not count.
"""

import argparse
import csv
import json
import sys
from collections import defaultdict
from pathlib import Path

AXI_MHZ = 450
PEAK_BYTES_PER_CYCLE = 32 * 32
BURST_BYTES = 512
STALL_MARGIN_CYCLES = 8
COLUMNS = [
    "phase",
    "port",
    "dir",
    "seq",
    "addr",
    "tag",
    "valid_cycle",
    "accept_cycle",
    "data_cycle",
    "done_cycle",
]


def load(path):
    with open(path, newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != COLUMNS:
            raise ValueError(f"Unexpected latency.csv header: {reader.fieldnames}")
        rows = []
        for raw in reader:
            row = {key: int(raw[key]) for key in COLUMNS if key not in ("phase", "dir", "addr")}
            row.update(phase=raw["phase"], dir=raw["dir"], addr=int(raw["addr"], 16))
            if (
                not row["valid_cycle"]
                <= row["accept_cycle"]
                <= row["data_cycle"]
                <= row["done_cycle"]
            ):
                raise ValueError(f"Cycle stamps out of order: {raw}")
            row["queue"] = row["accept_cycle"] - row["valid_cycle"]
            row["first"] = row["data_cycle"] - row["accept_cycle"]
            row["total"] = row["done_cycle"] - row["accept_cycle"]
            rows.append(row)
    if not rows:
        raise ValueError(f"No records in {path}")
    return rows


def percentile(values, fraction):
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, int(-(-fraction * len(ordered) // 1)) - 1))
    return ordered[index]


def stats(values):
    if not values:
        return None
    return {
        "count": len(values),
        "min": min(values),
        "p50": percentile(values, 0.5),
        "p90": percentile(values, 0.9),
        "p99": percentile(values, 0.99),
        "max": max(values),
        "mean": round(sum(values) / len(values), 2),
    }


def describe(rows):
    return {key: stats([r[key] for r in rows]) for key in ("queue", "first", "total")}


def throughput(rows):
    span = max(r["done_cycle"] for r in rows) - min(r["accept_cycle"] for r in rows)
    per_cycle = len(rows) * BURST_BYTES / span if span else 0.0
    return {
        "bytes_per_cycle": round(per_cycle, 2),
        "gb_per_s": round(per_cycle * AXI_MHZ / 1000, 2),
        "fraction_of_32_port_peak": round(per_cycle / PEAK_BYTES_PER_CYCLE, 4),
    }


def ordered(rows):
    return sorted(rows, key=lambda r: (r["port"], r["seq"]))


def idle_summary(rows):
    groups = defaultdict(list)
    for row in ordered(rows):
        groups[(row["port"], row["tag"] // 256)].append(row)
    table = []
    by_target = defaultdict(list)
    for (port, dst), group in sorted(groups.items()):
        warm = [r["first"] for r in group[1:]]
        target = "own" if dst == port else f"pc{dst}"
        by_target[target].extend(warm)
        table.append(
            {
                "port": port,
                "dst_pc": dst,
                "first_access": group[0]["first"],
                "repeat_p50": percentile(warm, 0.5) if warm else None,
            }
        )
    return {
        "by_target": {name: stats(values) for name, values in sorted(by_target.items())},
        "by_port": table,
    }


def stride_summary(rows):
    groups = defaultdict(list)
    for row in ordered(rows):
        groups[row["tag"]].append(row["first"])
    # The first two reads of each stride warm both rows; the rest show the pattern.
    table = {k: percentile(v[2:] or v, 0.5) for k, v in sorted(groups.items())}
    baseline = table.get(0)
    slow = []
    if baseline is not None:
        slow = [k for k, value in table.items() if k and value > baseline + STALL_MARGIN_CYCLES]
    return {"p50_by_stride_bit": table, "same_address_p50": baseline, "slow_stride_bits": slow}


def by_tag(rows):
    groups = defaultdict(list)
    for row in rows:
        groups[row["tag"]].append(row)
    return {tag: {**describe(group), **throughput(group)} for tag, group in sorted(groups.items())}


def completion_order(rows):
    """Count completions that overtake an earlier-issued request on the same port."""
    result = {}
    for name, keep in (("reads", "R"), ("writes", "W"), ("combined", None)):
        overtaken = 0
        by_port = defaultdict(list)
        for row in rows:
            if keep is None or row["dir"] == keep:
                by_port[row["port"]].append(row)
        for group in by_port.values():
            group.sort(key=lambda r: (r["done_cycle"], r["seq"]))
            seqs = [r["seq"] for r in group]
            overtaken += sum(1 for a, b in zip(seqs, seqs[1:]) if b < a)
        result[name] = {"in_order": overtaken == 0, "overtakes": overtaken}
    return result


def calibration(phases):
    """Fit hit/miss/stall values from one-at-a-time reads (idle, stride, depth 1)."""
    classes = defaultdict(list)
    for row in ordered(phases.get("PhaseIdle", [])):
        classes[("idle", row["port"], row["tag"] // 256)].append(row["first"])
    for key in list(classes):
        classes[key] = classes[key][1:]
    stride = defaultdict(list)
    for row in ordered(phases.get("PhaseStride", [])):
        stride[row["tag"]].append(row["first"])
    for bit, values in stride.items():
        classes[("stride", bit)] = values[2:]
    classes[("depth1",)] = [r["first"] for r in phases.get("PhaseDepth", []) if r["tag"] == 1]
    residuals = []
    for values in classes.values():
        if values:
            base = percentile(values, 0.5)
            residuals.extend(v - base for v in values)
    # The miss comes from port 0 striding within its own pseudo-channel, so the hit
    # uses the same route; reads through the switch are reported separately.
    hit = [
        v
        for key, values in classes.items()
        if key[0] == "idle" and key[1] == key[2]
        for v in values
    ]
    switched = [
        v
        for key, values in classes.items()
        if key[0] == "idle" and key[1] != key[2]
        for v in values
    ]
    strides = stride_summary(phases.get("PhaseStride", [])) if stride else None
    miss = None
    if strides and strides["slow_stride_bits"]:
        miss = percentile(
            [strides["p50_by_stride_bit"][k] for k in strides["slow_stride_bits"]], 0.5
        )
    stalls = [r for r in residuals if r > STALL_MARGIN_CYCLES]
    return {
        "hit_cycles": percentile(hit, 0.5) if hit else None,
        "hit_route": "own pseudo-channel",
        "switched_hit_cycles": percentile(switched, 0.5) if switched else None,
        "miss_cycles": miss,
        "miss_route": "port 0 within its own pseudo-channel",
        "stall_probability": round(len(stalls) / len(residuals), 4) if residuals else None,
        "stall_max_cycles": max(stalls) if stalls else 0,
        "samples": len(residuals),
    }


def summarize(rows):
    phases = defaultdict(list)
    for row in rows:
        phases[row["phase"]].append(row)
    result = {"records": len(rows), "phases": {}}
    for name, group in sorted(phases.items()):
        reads = [r for r in group if r["dir"] == "R"]
        writes = [r for r in group if r["dir"] == "W"]
        entry = {
            "reads": describe(reads) if reads else None,
            "completion_order": completion_order(group),
        }
        if writes:
            entry["writes"] = describe(writes)
        if name == "PhaseIdle":
            entry["idle"] = idle_summary(reads)
        elif name == "PhaseStride":
            entry["stride"] = stride_summary(reads)
        elif name == "PhaseDepth":
            entry["by_depth"] = by_tag(reads)
        elif name == "PhaseAllPorts":
            entry["throughput"] = throughput(reads)
        elif name == "PhaseMixed":
            entry["by_tag_reads"] = by_tag(reads) if reads else None
            entry["by_tag_writes"] = by_tag(writes) if writes else None
        result["phases"][name] = entry
    result["calibration"] = calibration(phases)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("csv", type=Path)
    parser.add_argument("--output", type=Path, help="Write the JSON summary here")
    args = parser.parse_args()
    try:
        result = summarize(load(args.csv))
    except (ValueError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    print(json.dumps(result["calibration"], indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
