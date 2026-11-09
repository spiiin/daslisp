"""Portable runner for upstream MAL test files (Python 3, no dependencies).

Understands the upstream ;=> literal returns and ;/ output regexes, and runs
deferrable/optional/soft tests as hard requirements. Each suite gets a fresh VM.
The fixture paths are resolved from upstream's impls/nim directory.
"""
import argparse
import codecs
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time


def cases(path):
    lines = path.read_text(encoding="utf-8").split("\n")
    i = 0
    while i < len(lines):
        form = lines[i]
        i += 1
        if not form.strip() or form.startswith(";"):
            continue
        line_number = i
        patterns = []
        returned = ""
        while i < len(lines):
            line = lines[i]
            if line.startswith(";=>"):
                returned = line[3:]
                i += 1
                break
            if line.startswith(";/"):
                patterns.append(line[2:])
                i += 1
            else:
                break
        expected = "\n".join(patterns)
        if expected and returned:
            expected += "\n"
        expected += re.escape(returned)
        if returned:
            expected += r"\Z"
        yield line_number, form, expected


def matches_output(expected, output):
    # Literal returns must start on a line boundary: expected 1 must not match
    # 11 or -1. Regex-only output expectations may intentionally omit the return.
    return not expected or re.search(r"(?:\A|\n)" + expected, output, re.S) is not None


def find_suites(mal_root, requested=None):
    test_root = mal_root.resolve() / "impls" / "tests"
    if not test_root.is_dir():
        raise ValueError(f"MAL test directory does not exist: {test_root}")
    suites = ([test_root / (name + ".mal") for name in requested] if requested
              else sorted(test_root.glob("step*.mal")))
    suites = [suite for suite in suites if not suite.name.startswith("step0")]
    if not suites:
        raise ValueError(f"No runnable MAL test suites in {test_root}")
    for suite in suites:
        if not suite.is_file():
            raise ValueError(f"MAL test suite does not exist: {suite}")
    return test_root, suites


class Repl:
    def __init__(self, command, cwd):
        self.process = subprocess.Popen(command, cwd=cwd, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.output = queue.Queue()
        self.buffer = ""

        def read():
            decoder = codecs.getincrementaldecoder("utf-8")("replace")
            while chunk := self.process.stdout.read(1):
                for char in decoder.decode(chunk):
                    self.output.put(char)
            self.output.put(None)

        threading.Thread(target=read, daemon=True).start()

    def prompt(self, timeout=45):
        end = time.monotonic() + timeout
        while True:
            match = re.search(r"(?:^|\n)[^\s()<>]+> $", self.buffer)
            if match:
                result = self.buffer[:match.start()]
                self.buffer = ""
                return result
            try:
                char = self.output.get(timeout=max(0, end - time.monotonic()))
            except queue.Empty:
                raise RuntimeError(f"REPL timed out: {self.buffer[-2000:]}") from None
            if char is None:
                raise RuntimeError(f"REPL exited ({self.process.poll()}): {self.buffer[-4000:]}")
            if char != "\r":
                self.buffer += char

    def send(self, form):
        # Upstream's time-ms test assumes distinct user interactions take at
        # least one millisecond. Fast Windows pipes can otherwise finish both
        # clock reads in the same millisecond. Preserve real clock semantics.
        time.sleep(0.002)
        self.process.stdin.write((form + "\n").encode("utf-8"))
        self.process.stdin.flush()

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process.stdout.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daslang", required=True)
    parser.add_argument("--mal", required=True, type=Path, help="upstream kanaka/mal checkout")
    parser.add_argument("--suite", action="append", help="e.g. step9_try (repeatable)")
    parser.add_argument("--self-host", action="store_true", help="also run MAL implemented in MAL")
    options = parser.parse_args(argv)
    entry = Path(__file__).resolve().parents[1] / "main.das"
    try:
        test_root, suites = find_suites(options.mal, options.suite)
    except ValueError as error:
        parser.error(str(error))
    total = failures = 0
    for suite in suites:
        suite_cases = list(cases(suite))
        if not suite_cases:
            parser.error(f"No test forms in {suite}")
        command = [options.daslang, str(entry)]
        if suite.name.startswith("step1"):
            command += ["--", "--reader"]
        repl = Repl(command, test_root.parent / "nim")
        passed = failed = 0
        try:
            repl.prompt()
            for line, form, expected in suite_cases:
                repl.send(form)
                try:
                    output = repl.prompt()
                except RuntimeError as error:
                    raise RuntimeError(f"{suite.name}:{line}: {form}\n{error}") from error
                if matches_output(expected, output):
                    passed += 1
                else:
                    failed += 1
                    print(f"FAIL {suite.name}:{line}: {form}\n  expected: {expected!r}\n  received: {output!r}")
        finally:
            repl.close()
        print(f"{suite.stem}: {passed} passed, {failed} failed", flush=True)
        total += passed + failed
        failures += failed
    print(f"TOTAL: {total - failures}/{total} passed; optional and deferrable included")
    if options.self_host and not failures:
        result = subprocess.run(
            [options.daslang, str(entry), "--", "../mal/stepA_mal.mal"],
            cwd=test_root.parent / "nim", input="(+ 2 3)\n(let* [x 4] (* x x))\n",
            encoding="utf-8", stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        if result.returncode or "mal-user> 5\n" not in result.stdout or "mal-user> 16\n" not in result.stdout:
            print(f"FAIL: MAL self-hosting\n{result.stdout}", file=sys.stderr)
            return 1
        print("PASS: MAL self-hosting")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
