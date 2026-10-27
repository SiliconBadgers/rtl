"""Check the latency bench wiring and that the analyzer recovers a known timing model."""

import random
import tempfile
import unittest
from pathlib import Path

import f2_hbm
import f2_hbm_latency

HIT, MISS, STALL, STALL_PROBABILITY = 55, 69, 40, 0.05
ROW_BITS = range(14, 29)  # synthetic map: these stride bits change the row


def synthetic_csv(path, seed=3):
    """Write records shaped like the probe's output from a known latency model."""
    rng = random.Random(seed)
    lines = [",".join(f2_hbm_latency.COLUMNS)]
    seq = {}
    cycle = 0

    def add(phase, port, direction, tag, latency, addr=0):
        nonlocal cycle
        if rng.random() < STALL_PROBABILITY:
            latency += STALL
        seq[port] = seq.get(port, -1) + 1
        valid, accept = cycle, cycle + 1
        data = accept + latency
        lines.append(
            f"{phase},{port},{direction},{seq[port]},{addr:x},{tag},"
            f"{valid},{accept},{data},{data + 15}"
        )
        cycle = data + 48

    for port in range(32):
        for dst in (port, 0, 16):
            for repeat in range(3):
                add("PhaseIdle", port, "R", dst * 256 + repeat, MISS if repeat == 0 else HIT)
    for bit in [0, *range(5, 29)]:
        for index in range(8):
            conflict = bit in ROW_BITS and index > 0
            add("PhaseStride", 0, "R", bit, MISS if conflict else HIT)
    for depth in (1, 2, 4, 8, 16, 32, 64):
        for _ in range(128):
            add("PhaseDepth", 0, "R", depth, HIT)
    for _ in range(64):
        add("PhaseMixed", 0, "W", 1, HIT + 20)
    path.write_text("\n".join(lines) + "\n")


class LatencyAnalyzerTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "latency.csv"
        synthetic_csv(self.path)

    def test_recovers_hit_miss_and_row_bits(self):
        result = f2_hbm_latency.summarize(f2_hbm_latency.load(self.path))
        calibration = result["calibration"]
        self.assertEqual(calibration["hit_cycles"], HIT)
        self.assertEqual(calibration["miss_cycles"], MISS)
        stride = result["phases"]["PhaseStride"]["stride"]
        self.assertEqual(stride["slow_stride_bits"], list(ROW_BITS))
        self.assertEqual(calibration["stall_max_cycles"], STALL)
        self.assertGreater(calibration["stall_probability"], 0.02)
        self.assertLess(calibration["stall_probability"], 0.10)

    def test_writes_are_summarized_separately(self):
        result = f2_hbm_latency.summarize(f2_hbm_latency.load(self.path))
        writes = result["phases"]["PhaseMixed"]["writes"]
        self.assertEqual(writes["first"]["p50"], HIT + 20)

    def test_rejects_wrong_header_and_unordered_stamps(self):
        self.path.write_text("phase,port\nPhaseIdle,0\n")
        with self.assertRaises(ValueError):
            f2_hbm_latency.load(self.path)
        header = ",".join(f2_hbm_latency.COLUMNS)
        self.path.write_text(header + "\nPhaseIdle,0,R,0,0,0,10,5,20,30\n")
        with self.assertRaises(ValueError):
            f2_hbm_latency.load(self.path)

    def test_empty_file_fails(self):
        self.path.write_text(",".join(f2_hbm_latency.COLUMNS) + "\n")
        with self.assertRaises(ValueError):
            f2_hbm_latency.load(self.path)


class LatencyBenchWiringTests(unittest.TestCase):
    def test_latency_bench_compiles_its_own_testbench(self):
        bench = f2_hbm.BENCHES["latency"]
        self.assertEqual(f2_hbm.sources("latency")[-1].name, bench["source"])
        self.assertTrue((f2_hbm.TEST / bench["source"]).is_file())
        self.assertNotEqual(bench["output"], f2_hbm.BENCHES["functional"]["output"])

    def test_latency_bench_has_negative_cases(self):
        expected = {e for _, e in f2_hbm.BENCHES["latency"]["cases"].values() if e}
        self.assertEqual(expected, {"HBM_LATENCY_MISSING", "HBM_RESET_REQUIRED"})

    def test_latency_positive_needs_its_own_marker(self):
        marker = f2_hbm.BENCHES["latency"]["marker"]
        self.assertTrue(f2_hbm.classify(0, "F2_HBM_LATENCY_DONE phases=63", None, marker))
        self.assertFalse(f2_hbm.classify(0, "F2_HBM_PASS ports=32", None, marker))
        self.assertFalse(f2_hbm.classify(1, "F2_HBM_LATENCY_DONE phases=63", None, marker))

    def test_missing_csv_fails_the_case(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                f2_hbm.summarize_latency(Path(directory))


if __name__ == "__main__":
    unittest.main()
