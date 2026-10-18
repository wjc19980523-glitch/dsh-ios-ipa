#!/usr/bin/env python3
"""Execute native test runners; cleanup must not turn failures into success."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("DSH_TEST_BASH", "/bin/bash")
NATIVE_NAMES = (
    "lifecycle-test.sh", "fakefs-db-failure-test.sh",
    "legacy-fakefs-wrapper-test.sh", "fakefs-quiesce-test.sh",
    "sockrestart-test.sh", "guest-exit-test.sh",
    "lifecycle-admission-test.sh", "lifecycle-poll-wait-test.sh",
    "lifecycle-sigsuspend-test.sh", "lifecycle-tty-read-test.sh",
    "futex-idle-test.sh",
    "flock-diagnostics-test.sh",
    "session-drain-admission-test.sh",
    "task-lifecycle-context-test.sh",
    "lifecycle-wait-diagnostics-test.sh",
)


class NativeRunnerTests(unittest.TestCase):
    def scripts(self):
        # Commit 1 contains the lifecycle runner; later commits add the others.
        # Exercise every runner present in the checked-out commit, never zero.
        present = [ROOT / "tests" / name for name in NATIVE_NAMES
                   if (ROOT / "tests" / name).is_file()]
        self.assertTrue(present, "no native runners were checked")
        return present

    def run_script(self, script, **overrides):
        environment = os.environ.copy()
        environment.update(CFLAGS="")
        environment.update(overrides)
        return subprocess.run([BASH, str(script)], cwd=ROOT, env=environment,
                              text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=120)

    def assert_lifecycle_completed(self, result):
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("All lifecycle diagnostic tests passed.", result.stdout)
        self.assertIn("PASS real fake-db SQLite hooks, direct SQL, implicit reads "
                      "and mutex-independent snapshots", result.stdout)
        self.assertEqual(sum(line.startswith("PASS ")
                             for line in result.stdout.splitlines()), 8,
                         result.stdout)

    def test_empty_cflags_executes_both_real_lifecycle_binaries(self):
        self.assert_lifecycle_completed(self.run_script(ROOT / "tests/lifecycle-test.sh"))

    def test_nonempty_cflags_executes_both_real_lifecycle_binaries(self):
        self.assert_lifecycle_completed(self.run_script(ROOT / "tests/lifecycle-test.sh",
                                                       CFLAGS="-O0 -g"))

    def test_every_present_runner_rejects_false_compiler(self):
        for script in self.scripts():
            with self.subTest(script=script.name):
                result = self.run_script(script, CC="/bin/false")
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_every_present_runner_preserves_reached_compiler_exit_code(self):
        with tempfile.TemporaryDirectory(prefix="dsh-native-runner.") as directory:
            compiler = Path(directory) / "compiler-fails"
            compiler.write_text("#!/bin/sh\necho DSH_NATIVE_COMPILER_REACHED >&2\nexit 73\n")
            compiler.chmod(0o755)
            for script in self.scripts():
                with self.subTest(script=script.name):
                    result = self.run_script(script, CC=str(compiler))
                    self.assertIn("DSH_NATIVE_COMPILER_REACHED", result.stdout)
                    self.assertEqual(result.returncode, 73, result.stdout)

    def test_cleanup_preserves_shell_expansion_failure(self):
        # Execute each real EXIT trap after an injected nounset expansion, which
        # failed before cc on Bash 3.2. This is a runtime check, not a grep.
        with tempfile.TemporaryDirectory(prefix="dsh-native-nounset.") as directory:
            for script in self.scripts() + [ROOT / "scripts/run-xctests.sh"]:
                with self.subTest(script=script.name):
                    source = script.read_text()
                    lines = source.splitlines(keepends=True)
                    trap_line = next(i for i, line in enumerate(lines)
                                     if line.startswith("trap ") and " EXIT" in line)
                    lines.insert(trap_line + 1,
                                 "unset DSH_NATIVE_UNSET_VALUE\n"
                                 "printf '%s' \"$DSH_NATIVE_UNSET_VALUE\"\n")
                    candidate = Path(directory) / script.parent.name / script.name
                    candidate.parent.mkdir(exist_ok=True)
                    candidate.write_text("".join(lines))
                    result = self.run_script(candidate)
                    self.assertIn("DSH_NATIVE_UNSET_VALUE", result.stdout)
                    self.assertIn("unbound variable", result.stdout)
                    self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_poll_wait_empty_flags_executes_all_real_scenarios(self):
        script = ROOT / "tests/lifecycle-poll-wait-test.sh"
        if not script.exists():
            # This runner is added in commit 3. Commit 1 still executes the
            # mandatory lifecycle and all failure-propagation checks above.
            self.skipTest("poll-wait runner is added in commit 3")
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stdout)
        for scenario in ("group-exit", "stale", "recent-resume", "quiescing", "idle"):
            self.assertIn("PASS production poll_wait " + scenario, result.stdout)


if __name__ == "__main__":
    print("Native runners: " + ", ".join(path.name for path in
          (ROOT / "tests" / name for name in NATIVE_NAMES) if path.is_file()), flush=True)
    unittest.main(verbosity=2)
