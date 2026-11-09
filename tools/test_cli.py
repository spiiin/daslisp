"""Exercise the actual command line, pipes, file loading and argument handling."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--daslang", required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[1]

    def run(*args, source="", cwd=None):
        return subprocess.run([options.daslang, str(root / "main.das"), "--", *args],
                              input=source, encoding="utf-8", stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, cwd=cwd or root, timeout=60)

    p = run("--eval", "(+ 20 22)")
    assert p.returncode == 0 and p.stdout.strip() == "42", p.stdout
    p = run("--eval", "(/ 1 0)")
    assert p.returncode != 0 and "division by zero" in p.stdout, p.stdout
    p = run("--read", source="'foo\n; comment\n[1 :a]\n")
    assert p.stdout.splitlines() == ["(quote foo)", "[1 :a]"], p.stdout
    p = run("--batch", source="(\n[1 2)\n(+ 1 2)\n")
    assert p.stdout.count("Error:") == 2 and p.stdout.rstrip().endswith("3"), p.stdout
    p = run(source='(def! plus (let* [x 2] (fn* [y] (+ x y))))\n(plus 5)\n')
    assert p.returncode == 0 and p.stdout.count("user> ") == 3 and "user> 7" in p.stdout, p.stdout
    # Surpass fgets' 16 KiB chunk size and keep one logical input line.
    large = "x" * 20000
    p = run("--batch", source=f'(count "{large}")\n')
    assert p.returncode == 0 and p.stdout.strip() == "20000", p.stdout
    # readline must consume a whole line too, leaving the next form untouched.
    p = run("--batch", source=f'(count (readline ""))\n{large}\n(+ 1 2)\n')
    assert p.returncode == 0 and p.stdout.splitlines() == ["20000", "3"], p.stdout
    p = run("--batch", source=f'(count (readline ""))\n{large}')
    assert p.returncode == 0 and p.stdout.strip() == "20000", p.stdout
    p = run("--batch", source='(readline "")\n\n(readline "")\n')
    assert p.returncode == 0 and p.stdout.splitlines() == ['""', 'nil'], p.stdout
    p = run("--batch", source='(readline "")\nhello world\r\n(+ 2 3)\n')
    assert p.returncode == 0 and p.stdout.splitlines() == ['"hello world"', '5'], p.stdout
    scratch = root / ".work"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="daslisp test ", dir=scratch) as folder:
        script = Path(folder) / "with spaces.mal"
        script.write_text('(println (first *ARGV*))\n(println (+ 4\n 5))\n', encoding="utf-8")
        p = run(str(script), 'a "quoted" argument', cwd=folder)
        assert p.returncode == 0 and p.stdout.splitlines() == ['a "quoted" argument', '9'], p.stdout
    p = run("__daslisp_missing__.mal")
    assert p.returncode != 0 and "cannot open" in p.stdout, p.stdout
    print("PASS: 12 CLI checks (REPL, EOF, readline, errors, long lines, files and ARGV)")


if __name__ == "__main__":
    main()
