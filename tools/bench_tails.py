"""A/B benchmark for walking an immutable list using rest; no JIT is enabled."""
import argparse
import json
from pathlib import Path
import statistics

from bench_mal import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daslang", required=True)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--sizes", nargs="+", type=int, default=[1000, 4000, 16000])
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--memory-limit-mib", type=int, default=1024)
    parser.add_argument("--output", required=True, type=Path)
    options = parser.parse_args()
    if options.repeat < 1 or any(size < 1 for size in options.sizes):
        parser.error("repeat and sizes must be positive")
    root = options.root.resolve()
    report = {"root": str(root), "daslang": options.daslang, "runs": {}}
    for size in options.sizes:
        results = report["runs"][str(size)] = []
        for index in range(options.repeat):
            command = [options.daslang, str(root / "tools" / "bench_tails.das"), "--", str(size)]
            result = run(command, root, 90, options.memory_limit_mib * 2**20)
            results.append(result)
            options.output.parent.mkdir(parents=True, exist_ok=True)
            options.output.write_text(json.dumps(report, indent=2), encoding="utf-8")
            print(f"size={size} #{index+1}: {result['status']} tail={result['tail']} "
                  f"peak_commit={result['peak_commit_mib']:.1f}MiB", flush=True)
            if result["status"] != "ok":
                break
        good = [r for r in results if r["status"] == "ok"]
        if good:
            print(f"size={size} median: {statistics.median(r['tail']['elapsed_ns'] for r in good)/1e6:.3f}ms", flush=True)
    return any(r["status"] != "ok" for rows in report["runs"].values() for r in rows)


if __name__ == "__main__":
    raise SystemExit(main())
