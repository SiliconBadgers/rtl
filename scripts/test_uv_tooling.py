"""Check locked uv routing without installing tools or running RTL simulation."""

import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class UvMakeTests(unittest.TestCase):
    def dry_run(self, target, *options):
        result = subprocess.run(
            [
                "make",
                "--no-print-directory",
                "-n",
                target,
                "UV=uv-probe",
                "PYTHON=python-probe",
                *options,
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_setup_uses_locked_sync(self):
        self.assertIn('"uv-probe" sync --locked', self.dry_run("setup"))

    def test_style_and_format_select_locked_dev_group(self):
        for target in ("style", "format"):
            with self.subTest(target=target):
                self.assertIn(
                    '"uv-probe" run --locked --group dev "python-probe" scripts/check_style.py',
                    self.dry_run(target),
                )

    def test_tooling_tests_use_locked_python(self):
        self.assertIn(
            '"uv-probe" run --locked "python-probe" -m unittest discover',
            self.dry_run("test-tooling"),
        )

    def test_uv_failure_is_not_ignored_and_override_handles_spaces(self):
        with tempfile.TemporaryDirectory(prefix="uv executable ") as folder:
            executable = Path(folder) / "uv stub"
            executable.write_text("#!/bin/sh\nexit 7\n")
            executable.chmod(0o755)
            result = subprocess.run(
                ["make", "--no-print-directory", "style", f"UV={executable}"],
                cwd=ROOT,
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Error 7", result.stderr)


class MatrixUvTests(unittest.TestCase):
    """Use recording uv and VCS fixtures; these are not hardware simulations."""

    def invoke_matrix(self, simulator_exit):
        with tempfile.TemporaryDirectory(prefix="matrix uv ") as folder:
            directory = Path(folder)
            checkout = directory / "RTL checkout with spaces"
            checkout.symlink_to(ROOT, target_is_directory=True)
            uv = directory / "uv fixture"
            uv.write_text(
                f"#!{sys.executable}\n"
                "import json, os, subprocess, sys\n"
                "from pathlib import Path\n"
                "args = sys.argv[1:]\n"
                "assert args[:4] == ['run', '--locked', '--project', os.environ['TEST_ROOT']]\n"
                "assert args[4] == 'selected python'\n"
                "with open(os.environ['UV_CALL_LOG'], 'a') as log:\n"
                "    log.write(json.dumps({'args': args, 'cwd': str(Path.cwd())}) + '\\n')\n"
                "raise SystemExit(subprocess.call([sys.executable, *args[5:]]))\n"
            )
            uv.chmod(0o755)
            launcher = directory / "VCS fixture.py"
            launcher.write_text(
                "import os, sys\n"
                "from pathlib import Path\n"
                "if '-ID' in sys.argv:\n"
                "    print('Compiler version = VCS Y-2026.03_Full64')\n"
                "elif '-o' in sys.argv:\n"
                "    Path(sys.argv[sys.argv.index('-o') + 1]).touch()\n"
                "else:\n"
                "    assert '-exitstatus' in sys.argv\n"
                "    print('RESULT fixture status=PASS checked=1')\n"
                "    raise SystemExit(int(os.environ['SIMULATOR_EXIT']))\n"
            )
            log = directory / "uv calls.jsonl"
            output = directory / "output with spaces"
            result = subprocess.run(
                [
                    "bash",
                    str(checkout / "tb/compute/Matrix_Unit/run_tests.sh"),
                    "--only",
                    "pe_acc16",
                    "--seeds",
                    "7",
                    "--out",
                    str(output),
                ],
                cwd=directory,
                env={
                    **os.environ,
                    "UV": str(uv),
                    "PYTHON": "selected python",
                    "TEST_ROOT": str(checkout),
                    "UV_CALL_LOG": str(log),
                    "VCS_LAUNCHER": shlex.join([sys.executable, str(launcher)]),
                    "SIMULATOR_EXIT": str(simulator_exit),
                },
                text=True,
                capture_output=True,
                timeout=30,
            )
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            summary = (output / "vcs/summary.md").read_text()
            return result, calls, summary

    def test_every_python_call_selects_project_after_chdir(self):
        result, calls, summary = self.invoke_matrix(0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 6)
        self.assertTrue(any("build/pe_acc16" in item["cwd"] for item in calls))
        self.assertIn("passed: 1, failed: 0", summary)

    def test_simulator_failure_still_fails_through_uv(self):
        result, calls, summary = self.invoke_matrix(3)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(calls), 6)
        self.assertIn("FAIL (exit 3)", summary)
        self.assertIn("passed: 0, failed: 1", summary)
