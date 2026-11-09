"""Summarize daScript/Chrome B/E trace events by function (times are microseconds)."""
import argparse
from collections import defaultdict
import json
from pathlib import Path


def summarize(trace):
    stacks = defaultdict(list)
    totals = defaultdict(lambda: dict(calls=0, inclusive_us=0, self_us=0))
    for event in trace:
        stack = stacks[event.get("tid")]
        if event.get("ph") == "B":
            stack.append([event["name"], event["ts"], 0])
        elif event.get("ph") == "E" and stack:
            name, start, children = stack.pop()
            elapsed = event["ts"] - start
            row = totals[name]
            row["calls"] += 1
            row["inclusive_us"] += elapsed
            row["self_us"] += elapsed - children
            if stack:
                stack[-1][2] += elapsed
    return sorted((dict(function=name, **row) for name, row in totals.items()),
                  key=lambda row: row["self_us"], reverse=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--top", type=int, default=20)
    options = parser.parse_args()
    source = options.trace.read_text(encoding="utf-8").rstrip()
    # Some SDK builds flush all events but omit the closing array bracket at
    # context shutdown. Still require every event object to be complete JSON.
    if not source.endswith("]"):
        source += "]"
    rows = summarize(json.loads(source))
    if options.output:
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(json.dumps(rows, indent=2), encoding="utf-8")
    for row in rows[:options.top]:
        print(f"{row['calls']:7d} calls {row['self_us']:9d} self_us {row['function']}")


if __name__ == "__main__":
    main()
