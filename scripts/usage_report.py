#!/usr/bin/env python3
"""Summarize the usage log written by skk-zenz.el (`skk-zenz-log-file').

Usage: scripts/usage_report.py LOG [--examples]

Sections:
  sources    where confirmed words came from, by reading length
  zenz       per trigger: status, latency, and the rank of the confirmed
             word among the zenz candidates
  rerank     how often reranking kept, fixed, or broke the first candidate
--examples lists confirmations where zenz was asked but its first candidate
was not the confirmed word.
"""
import json
import sys
from collections import Counter, defaultdict

BUCKETS = [(1, 3), (4, 5), (6, 7), (8, 9), (10, 14), (15, 999)]
SOURCES = ["dictionary", "zenz-long", "zenz-fallback", "registered"]


def bucket(key):
    n = len(key)
    for lo, hi in BUCKETS:
        if lo <= n <= hi:
            return f"{lo}-{hi}" if hi < 999 else f"{lo}+"
    return "?"


def percentile(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))] if values else 0


def table(title, header, rows):
    print(f"\n## {title}")
    widths = [max(len(str(r[i])) for r in [header] + rows) for i in range(len(header))]
    for r in [header] + rows:
        print("  ".join(str(c).rjust(w) for c, w in zip(r, widths)))


def okuri_nashi(record):
    return not record["okurigana"]


def report_sources(records):
    names = [f"{lo}-{hi}" if hi < 999 else f"{lo}+" for lo, hi in BUCKETS]
    groups = defaultdict(list)
    for r in records:
        groups[bucket(r["key"]) if okuri_nashi(r) else "okuri-ari"].append(r)
    rows = []
    for name in names + ["okuri-ari"]:
        g = groups.get(name, [])
        if not g:
            continue
        c = Counter(r["source"] for r in g)
        first = sum(r["index"] == 0 for r in g)
        rows.append([name, len(g)] + [c[s] for s in SOURCES]
                    + [f"{first / len(g):.2f}", f"{sum(r['index'] for r in g) / len(g):.2f}"])
    table("sources by reading length", ["length", "n"] + SOURCES + ["1st", "mean index"], rows)


def report_zenz(records):
    rows = []
    for trigger in ("long", "fallback"):
        g = [r["zenz"] | {"source": r["source"]} for r in records
             if r.get("zenz", {}).get("trigger") == trigger]
        if not g:
            continue
        status = Counter(z["status"] for z in g)
        ok = [z for z in g if z["status"] == "ok"]
        ms = [z["ms"] for z in ok]
        ranks = Counter(z["rank"] for z in ok)
        rows.append([trigger, len(g), status["ok"], status["timeout"],
                     status["error"] + status["unavailable"],
                     f"{sum(ms) / len(ms):.0f}" if ms else "-", percentile(ms, 0.95),
                     max(ms, default=0), sum(z["dropped"] for z in ok)]
                    + [ranks[i] for i in range(5)] + [ranks[None]])
    table("zenz requests (by the conversion that was confirmed)",
          ["trigger", "n", "ok", "timeout", "failed", "ms", "p95", "max", "dropped",
           "rank 0", "1", "2", "3", "4", "not in zenz"], rows)


def report_rerank(records):
    g = [r["rerank"] for r in records if "rerank" in r]
    if not g:
        return
    status = Counter(x["status"] for x in g)
    ok = [x for x in g if x["status"] == "ok"]
    ms = [x["ms"] for x in ok]
    c = Counter()
    for x in ok:
        before, after = x["rank-before"], x["rank-after"]
        if before is None:
            c["not in list"] += 1
        elif before == 0 and after == 0:
            c["kept"] += 1
        elif after == 0:
            c["fixed"] += 1
        elif before == 0:
            c["broken"] += 1
        else:
            c["other"] += 1
    table("rerank", ["n", "ok", "timeout", "failed", "ms", "p95", "max",
                     "kept", "fixed", "broken", "other", "not in list"],
          [[len(g), status["ok"], status["timeout"], status["error"] + status["unavailable"],
            f"{sum(ms) / len(ms):.0f}" if ms else "-", percentile(ms, 0.95), max(ms, default=0),
            c["kept"], c["fixed"], c["broken"], c["other"], c["not in list"]]])


def show_examples(records):
    print("\n## zenz misses (first zenz candidate was not confirmed)")
    for r in records:
        z = r.get("zenz")
        if z and z["status"] == "ok" and z["rank"] != 0:
            print(f"{r['time']} {z['trigger']:8} [{r['key']}] {r['word']} ({r['source']})"
                  f" zenz={z['candidates'][:3]}")


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        sys.exit(__doc__)
    records = []
    with open(args[0], encoding="utf-8") as f:
        for line in f:
            if line.strip():
                records.append(json.loads(line))
    if not records:
        sys.exit("no records")
    print(f"{len(records)} confirmations, {records[0]['time']} to {records[-1]['time']}")
    report_sources(records)
    report_zenz(records)
    report_rerank(records)
    if "--examples" in args:
        show_examples(records)


if __name__ == "__main__":
    main()
