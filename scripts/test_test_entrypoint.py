"""Ensure the default regression selects the current Matrix Unit suite."""

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class TestEntrypointTests(unittest.TestCase):
    def test_default_test_runs_matrix_unit(self):
        result = subprocess.run(
            ["make", "--no-print-directory", "-n", "test", "MATRIX_UNIT_ARGS=--seeds 7"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bash tb/compute/Matrix_Unit/run_tests.sh --seeds 7", result.stdout)
        for obsolete in ("generate_vectors.py", "mac-vectors", "run.py"):
            self.assertNotIn(obsolete, result.stdout)

    def test_obsolete_dut_is_not_retained(self):
        self.assertFalse((ROOT / "rtl/compute/pe_mac.sv").exists())
        self.assertFalse(list((ROOT / "rtl").rglob("pe_mac.sv")))


if __name__ == "__main__":
    unittest.main()
