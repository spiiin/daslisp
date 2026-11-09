"""Regressions for MAL test discovery and output matching; no MAL checkout needed."""
from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import test_mal as runner


class RunnerTests(unittest.TestCase):
    def setUp(self):
        scratch = Path(__file__).resolve().parents[1] / ".work"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="runner tests ", dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tests = self.root / "impls" / "tests"
        self.tests.mkdir(parents=True)

    def fixture(self, text="1\n;=>1\n", name="step1_read_print"):
        path = self.tests / (name + ".mal")
        path.write_text(text, encoding="utf-8")
        return path

    def expectation(self, source):
        return next(runner.cases(self.fixture(source)))[2]

    def test_literal_number_rejects_suffix_matches(self):
        expected = self.expectation("1\n;=>1\n")
        for output in ("11", "-1", "Error: 1", "1\n11"):
            with self.subTest(output=output):
                self.assertFalse(runner.matches_output(expected, output))
        self.assertTrue(runner.matches_output(expected, "1"))
        self.assertTrue(runner.matches_output(expected, "EVAL: 1\n1"))

    def test_literals_escape_regex_characters(self):
        expected = self.expectation('x\n;=>"a.b"\n')
        self.assertTrue(runner.matches_output(expected, '"a.b"'))
        self.assertFalse(runner.matches_output(expected, '"axb"'))

    def test_literal_return_must_be_complete(self):
        expected = self.expectation("x\n;=>nil\n")
        self.assertFalse(runner.matches_output(expected, "nil extra"))
        self.assertFalse(runner.matches_output(expected, "Error: nil"))
        self.assertTrue(runner.matches_output(expected, "\nnil"))

    def test_regex_output_and_literal_return(self):
        expected = self.expectation('x\n;/value: [0-9]+\n;=>nil\n')
        self.assertTrue(runner.matches_output(expected, "trace\nvalue: 42\nnil"))
        self.assertFalse(runner.matches_output(expected, "value: 42\nnot-nil"))

    def test_regex_only_allows_unchecked_return(self):
        expected = self.expectation('x\n;/hello.*world\n')
        self.assertTrue(runner.matches_output(expected, "hello world\nnil"))
        self.assertFalse(runner.matches_output(expected, "goodbye\nnil"))

    def test_ignored_return_remains_ignored(self):
        self.assertTrue(runner.matches_output("", "#<function>"))

    def test_discovers_runnable_suites(self):
        first = self.fixture()
        self.fixture("x", "step0_repl")
        root, suites = runner.find_suites(self.root)
        self.assertEqual(root, self.tests.resolve())
        self.assertEqual(suites, [first.resolve()])

    def test_missing_directory_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not exist"):
            runner.find_suites(self.root / "missing")

    def test_empty_directory_rejected(self):
        with self.assertRaisesRegex(ValueError, "No runnable"):
            runner.find_suites(self.root)

    def test_step_zero_only_rejected(self):
        self.fixture("x", "step0_repl")
        with self.assertRaisesRegex(ValueError, "No runnable"):
            runner.find_suites(self.root)

    def test_missing_named_suite_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not exist"):
            runner.find_suites(self.root, ["step9_try"])

    def test_empty_suite_rejected_before_starting_vm(self):
        self.fixture("; comments only\n")
        with patch.object(runner, "Repl") as repl, redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                runner.main(["--daslang", "unused", "--mal", str(self.root)])
            self.assertNotEqual(error.exception.code, 0)
            repl.assert_not_called()

    def test_wrong_result_fails_entire_run(self):
        self.fixture()
        fake = Mock()
        fake.prompt.side_effect = ["Mal", "11"]
        with patch.object(runner, "Repl", return_value=fake), redirect_stdout(io.StringIO()):
            self.assertTrue(runner.main(["--daslang", "unused", "--mal", str(self.root)]))
        fake.close.assert_called_once()

    def test_cli_missing_root_is_nonzero(self):
        result = subprocess.run([sys.executable, str(Path(runner.__file__)), "--daslang", "unused",
                                 "--mal", str(self.root / "missing")], capture_output=True,
                                encoding="utf-8", timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not exist", result.stderr)
        self.assertNotIn("0/0 passed", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
