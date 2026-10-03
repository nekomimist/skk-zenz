#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["fugashi", "unidic-lite"]
# ///
"""Offline evaluation of conversion with zenz, for tuning the client settings.

  collect  Cut Japanese text into phrases of one or more bunsetsu, as typed
           for zenz-first conversion of long readings, and into words (the
           noun part of each bunsetsu), as typed for ordinary SKK conversion.
           Convert each reading with zenz-server under several context lengths
           and candidate counts, look words up in SKK dictionaries, and write
           JSONL.
  report   Summarize a collected JSONL file: accuracy by context length, by
           candidate count, and by reading length (dictionary first vs zenz
           first), and the effect of dropping candidates by score gap.

Example:

  uv run scripts/eval_convert.py collect -o convert.jsonl \\
      --jisyo ~/.skk-jisyo --jisyo SKK-JISYO.L posts/*.org \\
      --ajimee AJIMEE-Bench/JWTD_v2/v1/evaluation_items.json
  uv run scripts/eval_convert.py report convert.jsonl

Text files are read as in eval_rerank.py.  --ajimee adds the items of
AJIMEE-Bench (https://github.com/azooKey/AJIMEE-Bench), which come with their
own readings, left contexts, and acceptable outputs.  The report shows each
corpus separately.
"""

import argparse
import json
import random
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from eval_rerank import (HIRAGANA_ONLY, JAPANESE_ONLY, KANJI, ROOT, Server,  # noqa: E402
                         clean_lines, load_jisyo, scorable, to_hiragana, word_kana)

DICT_SCORED = 20
BUCKETS = [(1, 3), (4, 5), (6, 7), (8, 9), (10, 11), (12, 14), (15, 19), (20, 999)]
# Parts of speech that join the preceding bunsetsu.
ATTACHED = ("助詞", "助動詞", "接尾辞")
# Parts of speech allowed in a "word" instance.
WORD_POS = ("名詞", "代名詞", "接頭辞", "接尾辞", "形状詞")


# ---------------------------------------------------------------- extraction


def bunsetsu_runs(line, tagger):
    """Yield runs of bunsetsu in `line`, split at symbols and non-Japanese
    words.  A bunsetsu is a list of words (start, end, reading, pos1)."""
    run = []
    pos = 0
    for w in tagger(line):
        start = line.find(w.surface, pos)
        if start < 0:
            break
        end = start + len(w.surface)
        kana = word_kana(w)
        pos1 = w.feature.pos1
        pos = end
        word = (start, end, kana, pos1)
        if run and run[-1][-1][1] != start:
            yield run
            run = []
        if not JAPANESE_ONLY.match(w.surface) or pos1 in ("補助記号", "記号", "空白") \
           or not kana or not HIRAGANA_ONLY.match(kana):
            if run:
                yield run
            run = []
            continue
        dependent = pos1 in ATTACHED or (pos1 in ("動詞", "形容詞")
                                         and w.feature.pos2 == "非自立可能")
        if not run:
            # Words left over from a dropped bunsetsu, as in "Emacsを".
            if not dependent:
                run.append([word])
            continue
        prev = run[-1][-1][3]
        if dependent or prev == "接頭辞" or (pos1 == "名詞" and prev == "名詞"):
            run[-1].append(word)
        else:
            run.append([word])
    if run:
        yield run


def content_word(bunsetsu):
    """Return the leading words of `bunsetsu` that SKK converts as one
    okuri-nashi reading (nouns with prefixes and suffixes), or None."""
    words = []
    for w in bunsetsu:
        if w[3] in ("助詞", "助動詞") or (words and w[3] in ("動詞", "形容詞")):
            break
        words.append(w)
    if not words or any(w[3] not in WORD_POS for w in words):
        return None
    return words


def extract_text(path, dicts, tagger, rng, max_bunsetsu, left_chars):
    """Yield instances from an Org or Markdown file.  Each run of bunsetsu is
    cut into phrases of 1 to `max_bunsetsu` bunsetsu chosen at random.  The
    content word of each bunsetsu is also an instance of kind "word"."""
    doc = ""
    for line in clean_lines(Path(path).read_text(encoding="utf-8")):
        if doc:
            doc += "\n"
        base = len(doc)
        doc += line

        def instance(kind, words, **extra):
            start, end = words[0][0], words[-1][1]
            kana = "".join(w[2] for w in words)
            return {"corpus": "text", "kind": kind, "file": str(path), "kana": kana,
                    "gold": [line[start:end]],
                    "left": doc[max(0, base + start - left_chars):base + start],
                    "dict": lookup(dicts, kana) if kind == "word" else [], **extra}

        for run in bunsetsu_runs(line, tagger):
            for b in run:
                words = content_word(b)
                if words and KANJI.search(line[words[0][0]:words[-1][1]]):
                    yield instance("word", words)
            i = 0
            while i < len(run):
                k = rng.randint(1, max_bunsetsu)
                chunk = run[i:i + k]
                i += k
                words = [w for b in chunk for w in b]
                if KANJI.search(line[words[0][0]:words[-1][1]]):
                    yield instance("phrase", words, bunsetsu=len(chunk))


def extract_ajimee(path, dicts):
    for item in json.loads(Path(path).read_text(encoding="utf-8")):
        kana = to_hiragana(item["input"])
        yield {"corpus": "ajimee", "kind": "phrase", "file": f"{path}#{item['index']}", "kana": kana,
               "gold": item["expected_output"], "left": item["context_text"],
               "dict": lookup(dicts, kana)}


def lookup(dicts, kana):
    """Return the union of dictionary candidates for `kana`, personal first."""
    union = []
    for d in dicts:
        union += [w for w in d.get(kana, []) if w not in union and scorable(w)]
    return union[:DICT_SCORED]


# ---------------------------------------------------------------- collect


def trim_left(left, chars):
    left = left.replace("\n", "")
    return left[-chars:] if chars > 0 else ""


def run_key(ctx, n):
    return f"c{ctx}/n{n}"


def cmd_collect(args):
    import fugashi

    tagger = fugashi.Tagger()
    dicts = [load_jisyo(p) for p in args.jisyo]
    contexts = [int(x) for x in args.contexts.split(",")]
    ns = [int(x) for x in args.ns.split(",")]
    plan = sorted({(c, args.ref_n) for c in contexts} | {(args.ref_context, n) for n in ns})
    max_ctx = max(contexts + [args.ref_context])

    rng = random.Random(args.seed)
    insts = []
    for path in args.files:
        insts += extract_text(path, dicts, tagger, rng, args.max_bunsetsu, max_ctx)
    for path in args.ajimee:
        insts += extract_ajimee(path, dicts)
    print(f"{len(insts)} instances, {len(plan)} conversions each", file=sys.stderr)

    server = Server(args.server, args.model, ["--max-context", str(max_ctx)])
    started = time.perf_counter()
    with open(args.output, "w", encoding="utf-8") as out:
        for i, inst in enumerate(insts):
            inst["runs"] = {}
            for ctx, n in plan:
                t = time.perf_counter()
                cands, scores = server.convert(inst["kana"], trim_left(inst["left"], ctx), "", n)
                inst["runs"][run_key(ctx, n)] = {
                    "candidates": cands, "scores": scores,
                    "ms": round((time.perf_counter() - t) * 1000, 1)}
            if inst["dict"]:
                texts = inst["dict"]
                inst["dict_scores"] = server.score(
                    inst["kana"], trim_left(inst["left"], args.ref_context), "", texts)
            out.write(json.dumps(inst, ensure_ascii=False) + "\n")
            if (i + 1) % 100 == 0:
                print(f"{i + 1}/{len(insts)} ({time.perf_counter() - started:.0f} s)",
                      file=sys.stderr)
    print(f"{len(insts)} instances written to {args.output}", file=sys.stderr)


# ---------------------------------------------------------------- report


def bucket(kana):
    n = len(kana)
    for lo, hi in BUCKETS:
        if lo <= n <= hi:
            return f"{lo}-{hi}" if hi < 999 else f"{lo}+"
    return "?"


def bucket_names():
    return [f"{lo}-{hi}" if hi < 999 else f"{lo}+" for lo, hi in BUCKETS]


def rank_of(gold, cands):
    """Return the 0-based rank of the first acceptable candidate, or None."""
    for i, c in enumerate(cands):
        if c in gold:
            return i
    return None


def promoted(inst, theta):
    """Dictionary order with the promote rerank applied (as skk-zenz-rerank)."""
    order = list(inst["dict"])
    scores = inst.get("dict_scores")
    if theta is None or not scores or len(order) < 2:
        return order
    best = max(range(len(order)), key=lambda i: scores[i])
    if best != 0 and scores[best] - scores[0] > theta:
        order.insert(0, order.pop(best))
    return order


def merged(first, second):
    return first + [w for w in second if w not in first]


def pct(num, den):
    return f"{num / den:6.3f}" if den else "     -"


def percentile(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))] if values else 0.0


def table(title, header, rows):
    print(f"\n### {title}")
    widths = [max(len(str(r[i])) for r in [header] + rows) for i in range(len(header))]
    for r in [header] + rows:
        print("  ".join(str(c).rjust(w) for c, w in zip(r, widths)))


def report_runs(insts, keys, title):
    """Accuracy and latency for each run, overall and by reading length."""
    names = bucket_names()
    rows = []
    for key in keys:
        runs = [(inst, inst["runs"][key]) for inst in insts if key in inst["runs"]]
        if not runs:
            continue
        top1 = sum(rank_of(i["gold"], r["candidates"]) == 0 for i, r in runs)
        found = sum(rank_of(i["gold"], r["candidates"]) is not None for i, r in runs)
        ms = [r["ms"] for _, r in runs]
        by = defaultdict(lambda: [0, 0])
        for i, r in runs:
            b = by[bucket(i["kana"])]
            b[0] += 1
            b[1] += rank_of(i["gold"], r["candidates"]) == 0
        rows.append([key, len(runs), pct(top1, len(runs)), pct(found, len(runs)),
                     f"{sum(ms) / len(ms):.0f}", f"{percentile(ms, 0.95):.0f}"]
                    + [pct(by[b][1], by[b][0]) for b in names])
    table(title, ["run", "n", "top1", "found", "ms", "p95"] + [f"@1 {b}" for b in names], rows)


def report_policy(insts, args):
    """Dictionary first vs zenz first, by reading length.  Only instances whose
    reading has dictionary candidates differ between the two."""
    long_key = run_key(args.ref_context, args.long_n)
    fb_key = run_key(args.ref_context, args.fallback_n)
    rows = []
    for name in bucket_names() + ["all"]:
        group = [i for i in insts if name in ("all", bucket(i["kana"]))
                 and long_key in i["runs"] and fb_key in i["runs"]]
        with_dict = [i for i in group if i["dict"]]
        c = defaultdict(float)
        for i in with_dict:
            d = promoted(i, args.theta)
            zl = i["runs"][long_key]["candidates"]
            zf = i["runs"][fb_key]["candidates"]
            c["dict1"] += rank_of(i["gold"], d) == 0
            c["zenz1"] += rank_of(i["gold"], zl) == 0
            for label, order in (("mrr_z", merged(zl, d)), ("mrr_d", merged(d, zf))):
                r = rank_of(i["gold"], order)
                c[label] += 0 if r is None else 1 / (r + 1)
        n = len(with_dict)
        rows.append([name, len(group), n, pct(c["dict1"], n), pct(c["zenz1"], n),
                     pct(c["mrr_d"], n), pct(c["mrr_z"], n)])
    table(f"dictionary first vs zenz first ({long_key}, rerank theta={args.theta})",
          ["length", "all", "in dict", "dict@1", "zenz@1", "MRR dict 1st", "MRR zenz 1st"],
          rows)


def report_gap(insts, args):
    """Effect of dropping candidates whose score trails the best by > T."""
    key = run_key(args.ref_context, args.fallback_n)
    runs = [(i, i["runs"][key]) for i in insts if key in i["runs"]]
    rows = []
    for t in [float(x) for x in args.gaps.split(",")]:
        dropped = total = lost = gold_lower = 0
        for i, r in runs:
            scores = r["scores"]
            rank = rank_of(i["gold"], r["candidates"])
            for k in range(1, len(scores)):
                total += 1
                if scores[0] - scores[k] > t:
                    dropped += 1
                    lost += rank == k
            gold_lower += rank is not None and rank > 0
        rows.append([f"{t:g}", pct(dropped, total), lost, gold_lower])
    table(f"dropping candidates trailing the best by more than T ({key})",
          ["T", "dropped", "gold lost", "gold below 1st"], rows)


def cmd_report(args):
    insts = [json.loads(l) for l in open(args.input, encoding="utf-8")]
    keys = sorted({k for i in insts for k in i["runs"]},
                  key=lambda k: tuple(int(x[1:]) for x in k.split("/")))
    for corpus, kind in sorted({(i["corpus"], i["kind"]) for i in insts}):
        group = [i for i in insts if i["corpus"] == corpus and i["kind"] == kind]
        print(f"\n## {corpus}, {kind}s ({len(group)} instances)")
        report_runs(group, [k for k in keys if k.endswith(f"/n{args.ref_n}")],
                    "context length")
        report_runs(group, [k for k in keys if k.startswith(f"c{args.ref_context}/")],
                    "candidates")
        if kind == "word":
            report_policy(group, args)
        report_gap(group, args)
    if args.examples:
        show_examples(insts, args)


def show_examples(insts, args):
    """Print instances where zenz's best candidate is not acceptable."""
    key = args.examples
    print(f"\n## misses of {key}")
    for i in insts:
        r = i["runs"].get(key)
        if r and rank_of(i["gold"], r["candidates"]) != 0:
            rank = rank_of(i["gold"], r["candidates"])
            print(f"{'-' if rank is None else rank} …{i['left'].replace(chr(10), '⏎')[-12:]}"
                  f"[{i['kana']}] gold={i['gold'][0]} zenz={r['candidates'][:3]}")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("files", nargs="*")
    c.add_argument("-o", "--output", required=True)
    c.add_argument("--jisyo", action="append", default=[],
                   help="SKK dictionary; repeat, personal dictionary first")
    c.add_argument("--ajimee", action="append", default=[],
                   help="AJIMEE-Bench evaluation_items.json")
    c.add_argument("--server", default=str(ROOT / "build" / "zenz-server"))
    c.add_argument("--model", default=str(ROOT / "models" / "zenz-v3.2-small-Q5_K_M.gguf"))
    c.add_argument("--contexts", default="0,10,20,40,80",
                   help="left context lengths to try with --ref-n candidates")
    c.add_argument("--ns", default="1,3,5,8",
                   help="candidate counts to try with --ref-context")
    c.add_argument("--ref-context", type=int, default=40)
    c.add_argument("--ref-n", type=int, default=5)
    c.add_argument("--max-bunsetsu", type=int, default=6)
    c.add_argument("--seed", type=int, default=0)
    r = sub.add_parser("report")
    r.add_argument("input")
    r.add_argument("--ref-context", type=int, default=40)
    r.add_argument("--ref-n", type=int, default=5)
    r.add_argument("--long-n", type=int, default=3,
                   help="candidates for long readings (skk-zenz-long-candidates)")
    r.add_argument("--fallback-n", type=int, default=5,
                   help="candidates after the dictionaries (skk-zenz-fallback-candidates)")
    r.add_argument("--theta", type=float, default=1.0,
                   help="promote threshold for dictionary order; -1 disables reranking")
    r.add_argument("--gaps", default="2,4,6,8,10")
    r.add_argument("--examples", metavar="RUN", help='list misses of RUN, e.g. "c40/n3"')
    args = p.parse_args()
    if args.cmd == "report" and args.theta < 0:
        args.theta = None
    if args.cmd == "collect" and not (args.files or args.ajimee):
        p.error("give text files or --ajimee")
    {"collect": cmd_collect, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    main()
