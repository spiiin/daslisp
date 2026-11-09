"""Run unchanged upstream MAL perf1/perf2/perf3, recording time and peak memory."""
import argparse
import ctypes
import json
import hashlib
import platform
from pathlib import Path
import re
import statistics
import subprocess
import time


def memory_reader(pid):
    if not hasattr(ctypes, "WinDLL"):
        return lambda: (0, 0), lambda: None
    from ctypes import wintypes

    class Counters(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD)] + [
            (name, ctypes.c_size_t) for name in ("PeakWorkingSetSize", "WorkingSetSize",
                "QuotaPeakPagedPoolUsage", "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage",
                "QuotaNonPagedPoolUsage", "PagefileUsage", "PeakPagefileUsage", "PrivateUsage")]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    psapi.GetProcessMemoryInfo.argtypes = [wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD]
    handle = kernel.OpenProcess(0x410, False, pid)

    def read():
        data = Counters()
        data.cb = ctypes.sizeof(data)
        if handle and psapi.GetProcessMemoryInfo(handle, ctypes.byref(data), data.cb):
            return data.PeakWorkingSetSize, data.PeakPagefileUsage
        return 0, 0

    return read, lambda: kernel.CloseHandle(handle) if handle else None


def run(command, cwd, timeout, memory_limit):
    start = time.perf_counter()
    process = subprocess.Popen(command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL)
    memory, close = memory_reader(process.pid)
    peak_rss = peak_commit = 0
    status = "ok"
    try:
        while process.poll() is None:
            rss, commit = memory()
            peak_rss, peak_commit = max(peak_rss, rss), max(peak_commit, commit)
            if peak_commit > memory_limit:
                status = "memory_limit"
            elif time.perf_counter() - start > timeout:
                status = "timeout"
            if status != "ok":
                process.kill()
                break
            time.sleep(0.025)
        output = process.communicate()[0].decode("utf-8", "replace").replace("\r\n", "\n")
        rss, commit = memory()
        peak_rss, peak_commit = max(peak_rss, rss), max(peak_commit, commit)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        close()
    if status == "ok" and (process.returncode or "Error:" in output or "EXCEPTION" in output):
        status = "error"
    elapsed = re.search(r"Elapsed time: (\d+) msecs", output)
    iterations = re.search(r"iters over 10 seconds:\s*(\d+)", output)
    fixed = re.search(r"BENCH iterations=(\d+) eval_ns=(\d+) gc_ns=(\d+) peak_values=(\d+) peak_envs=(\d+) result=(.*)", output)
    tail = re.search(r"TAIL size=(\d+) elapsed_ns=(\d+) values=(\d+) envs=(\d+) collections=(\d+) result=(\d+)", output)
    if status == "ok" and not (elapsed or iterations or fixed or tail):
        status = "error"
    return dict(status=status, wall_s=time.perf_counter() - start, peak_rss_mib=peak_rss / 2**20,
                peak_commit_mib=peak_commit / 2**20, elapsed_ms=int(elapsed[1]) if elapsed else None,
                iterations=int(iterations[1]) if iterations else None,
                fixed=dict(zip(("iterations", "eval_ns", "gc_ns", "peak_values", "peak_envs"),
                               map(int, fixed.groups()[:5])), result=fixed[6]) if fixed else None,
                tail=dict(zip(("size", "elapsed_ns", "values", "envs", "collections", "result"),
                              map(int, tail.groups()))) if tail else None,
                output=output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daslang", required=True)
    parser.add_argument("--mal", required=True, type=Path)
    parser.add_argument("--entry", type=Path, default=Path(__file__).resolve().parents[1] / "main.das")
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--suite", action="append", choices=["perf1", "perf2", "perf3"])
    parser.add_argument("--timeout", type=float, default=90)
    parser.add_argument("--memory-limit-mib", type=int, default=1024)
    parser.add_argument("--fixed-iterations", type=int, default=0,
                        help="also repeat exact perf1/perf2 timed forms outside parsing/loading")
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if options.repeat < 1 or options.fixed_iterations < 0:
        parser.error("repeat must be positive and fixed iterations nonnegative")
    cwd = options.mal.resolve() / "impls" / "nim"
    if not (cwd.parent / "tests" / "perf3.mal").is_file():
        parser.error("--mal must point to a kanaka/mal checkout")
    digest = hashlib.sha256()
    for source in sorted(options.entry.resolve().parent.glob("*.das")):
        digest.update(source.name.encode())
        digest.update(source.read_bytes())
    results = dict(daslang=options.daslang, entry=str(options.entry.resolve()),
                   source_sha256=digest.hexdigest(), platform=platform.platform(),
                   repeat=options.repeat, fixed_iterations=options.fixed_iterations, runs={})
    suites = options.suite or ["perf1", "perf2", "perf3"]
    if options.fixed_iterations:
        suites = suites + ["fixed_perf1", "fixed_perf2"]
    for suite in suites:
        runs = results["runs"][suite] = []
        for number in range(options.repeat):
            if suite.startswith("fixed_"):
                entry = options.entry.resolve().parent / "tools" / "bench_eval.das"
                command = [options.daslang, str(entry), "--", suite[6:], str(options.fixed_iterations)]
            else:
                command = [options.daslang, str(options.entry.resolve()), "--", f"../tests/{suite}.mal"]
            result = run(command, cwd, options.timeout, options.memory_limit_mib * 2**20)
            runs.append(result)
            options.output.parent.mkdir(parents=True, exist_ok=True)
            options.output.write_text(json.dumps(results, indent=2), encoding="utf-8")
            print(f"{suite} #{number+1}: {result['status']} wall={result['wall_s']:.3f}s "
                  f"elapsed={result['elapsed_ms']}ms iterations={result['iterations']} "
                  f"peak_commit={result['peak_commit_mib']:.1f}MiB fixed={result['fixed']}", flush=True)
            if result["status"] != "ok":
                break
        good = [r for r in runs if r["status"] == "ok"]
        if good:
            print(f"{suite} median wall: {statistics.median(r['wall_s'] for r in good):.3f}s", flush=True)
    return any(r["status"] != "ok" for runs in results["runs"].values() for r in runs)


if __name__ == "__main__":
    raise SystemExit(main())
