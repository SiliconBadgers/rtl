"""Check failure propagation, portable timing, and the project's constant-name policy."""

import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ProcessWrapperTests(unittest.TestCase):
    def run_command(self, command, timeout=3):
        with tempfile.TemporaryDirectory() as folder:
            elapsed = Path(folder) / "elapsed.txt"
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/run_with_timeout.py"),
                    "--timeout",
                    str(timeout),
                    "--elapsed-file",
                    str(elapsed),
                    "--",
                    *command,
                ],
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertGreaterEqual(float(elapsed.read_text()), 0)
            return result

    def test_success_preserves_arguments_with_spaces(self):
        result = self.run_command([sys.executable, "-c", "import sys; print(sys.argv[1])", "a b"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "a b\n")

    def test_failure_exit_is_preserved(self):
        result = self.run_command([sys.executable, "-c", "raise SystemExit(7)"])
        self.assertEqual(result.returncode, 7)

    def test_timeout_fails(self):
        result = self.run_command([sys.executable, "-c", "import time; time.sleep(30)"], 0.1)
        self.assertEqual(result.returncode, 124)
        self.assertIn("Timed out", result.stdout)

    def test_missing_executable_fails(self):
        result = self.run_command(["/nonexistent/siliconbadgers-test-command"])
        self.assertEqual(result.returncode, 127)


class ConstantNamingTests(unittest.TestCase):
    def lint(self, name, kind="localparam"):
        config = json.loads((ROOT / "style.json").read_text())
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "constant_policy.sv"
            source.write_text(f"module constant_policy;\n  {kind} int {name} = 1;\nendmodule\n")
            return subprocess.run(
                [
                    "verible-verilog-lint",
                    "--ruleset=default",
                    *[f"--rules={rule}" for rule in config["verible_lint_rules"]],
                    str(source),
                ],
                text=True,
                capture_output=True,
                check=False,
            )

    def test_all_caps_localparam_passes(self):
        self.assertEqual(self.lint("LATENCY_CYCLES").returncode, 0)

    def test_camel_case_localparam_fails(self):
        result = self.lint("LatencyCycles")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("parameter-name-style", result.stdout + result.stderr)

    def test_camel_case_parameter_passes(self):
        self.assertEqual(self.lint("LatencyCycles", "parameter").returncode, 0)

    def test_all_caps_parameter_fails(self):
        result = self.lint("LATENCY_CYCLES", "parameter")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("parameter-name-style", result.stdout + result.stderr)


class VcsToolingTests(unittest.TestCase):
    """Exercise orchestration failures without requiring a licensed CI installation."""

    def invoke(self, action, version="Y-2026.03_Full64"):
        with tempfile.TemporaryDirectory(prefix="vcs tooling ") as folder:
            directory = Path(folder)
            launcher = directory / "site launcher.py"
            launcher.write_text(
                "import sys\n"
                "if '-ID' in sys.argv:\n"
                f"    print('Compiler version = VCS {version}')\n"
                "else:\n"
                "    print('Fatal: deliberately failing tooling fixture')\n"
                "    raise SystemExit(3 if '-exitstatus' in sys.argv else 0)\n"
            )
            binary = directory / "simv"
            binary.touch()
            elapsed = directory / "elapsed"
            args = [str(binary)] if action == "run" else []
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/vcs.py"),
                    "--elapsed-file",
                    str(elapsed),
                    action,
                    *args,
                ],
                env={**os.environ, "VCS_LAUNCHER": shlex.join([sys.executable, str(launcher)])},
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertGreaterEqual(float(elapsed.read_text()), 0)
            return result

    def test_fatal_exit_survives_site_launcher_with_spaces(self):
        result = self.invoke("run")
        self.assertEqual(result.returncode, 3)
        self.assertIn("deliberately failing tooling fixture", result.stdout)

    def test_unvalidated_vcs_version_is_rejected(self):
        result = self.invoke("check", version="X-2025.06_Full64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsupported VCS version", result.stderr)

    def test_unrecognized_vcs_output_is_rejected(self):
        result = self.invoke("check", version="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VCS version check failed", result.stderr)

    def test_other_simulators_cannot_be_selected(self):
        for simulator in ("icarus", "verilator"):
            with self.subTest(simulator=simulator):
                result = subprocess.run(
                    ["bash", str(ROOT / "tb/compute/Matrix_Unit/run_tests.sh"), "--sim", simulator],
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("VCS is the required simulator", result.stderr)


if __name__ == "__main__":
    unittest.main()
