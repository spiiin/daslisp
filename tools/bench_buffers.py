"""Compare bounded suffix-copy/equality kernels without parsing, setup or JIT."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics

from bench_mal import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daslang", required=True)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--size", type=int, default=16000)
    parser.add_argument("--iterations", type=int, default=200)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--output", required=True, type=Path)
    options = parser.parse_args()
    if min(options.size, options.iterations, options.repeat) < 1:
        parser.error("size, iterations and repeat must be positive")
    root = options.root.resolve()
    digest = hashlib.sha256()
    for source in sorted(root.glob("*.das")):
        digest.update(source.name.encode())
        digest.update(source.read_bytes())
    report = dict(root=str(root), daslang=options.daslang, source_sha256=digest.hexdigest(),
                  size=options.size, iterations=options.iterations, repeat=options.repeat, runs={})
    for operation in ("copy", "equal"):
        results = report["runs"][operation] = []
        for index in range(options.repeat):
            command = [options.daslang, str(root / "tools/bench_buffers.das"), "--",
                       operation, str(options.size), str(options.iterations)]
            result = run(command, root, 90, 1024 * 2**20)
            results.append(result)
            options.output.parent.mkdir(parents=True, exist_ok=True)
            options.output.write_text(json.dumps(report, indent=2), encoding="utf-8")
            print(f"{operation} #{index+1}: {result['status']} {result['fixed']}", flush=True)
            if result["status"] != "ok":
                break
        good = [r for r in results if r["status"] == "ok"]
        if good:
            print(f"{operation} median: {statistics.median(r['fixed']['eval_ns'] for r in good)/1e6:.3f}ms", flush=True)
    return any(r["status"] != "ok" for rows in report["runs"].values() for r in rows)


if __name__ == "__main__":
    raise SystemExit(main())
