#!/usr/bin/env python3
"""Simulate reranking with `skk-zenz-rerank-learn` on words zenz does not know.

Each case is a reading, the word the user keeps in the personal dictionary
(a name, a preferred variant, a rare word), and a sequence of uses: a left
context and the word the user wants there, which is sometimes a rival.  The
personal dictionary starts with the user's word.  For every use the script
merges the personal dictionary and SKK-JISYO.L, reranks the candidates,
lets the user confirm the wanted word, and applies SKK's learning (the
confirmed word moves to the head of the personal dictionary) and, for the
`+learn` methods, the rerank learning of skk-zenz.el.

Reported per method: how often the wanted word came first, and the extra
SPC presses (its rank), separately for the user's word and for rivals.

Example:

  scripts/eval_rerank_learn.py --jisyo SKK-JISYO.L
  scripts/eval_rerank_learn.py --jisyo SKK-JISYO.L --no-context
"""

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

from eval_rerank import ROOT, Server, load_jisyo, scorable

LIMIT = 20  # skk-zenz-rerank-limit


def promote(order, s, theta):
    """`promote' in skk-zenz--rerank-words."""
    if order[0] not in s:
        return order
    best = max((w for w in order if w in s), key=lambda w: s[w])
    if best != order[0] and s[best] - s[order[0]] > theta:
        return [best] + [w for w in order if w != best]
    return order


def mix(order, s, beta):
    """`mix' in skk-zenz--rerank-words: sort scored words in their slots."""
    slots = [i for i, w in enumerate(order) if w in s]
    ranked = sorted(slots, key=lambda i: -(s[order[i]] - beta * math.log1p(i)))
    result = list(order)
    for slot, i in zip(slots, ranked):
        result[slot] = order[i]
    return result


class Method:
    def __init__(self, name, rerank, learn):
        self.name, self.rerank, self.learn = name, rerank, learn

    def run(self, case, jisyo, score):
        """Return [(wanted, rank)] for the uses of `case`."""
        personal = [case["word"]]
        boost = None  # (word, gap), one per reading
        out = []
        for left, wanted in case["uses"]:
            order = personal + [w for w in jisyo.get(case["kana"], []) if w not in personal]
            if wanted not in order:
                raise SystemExit(f"{wanted} is not a candidate for {case['kana']}")
            raw = score(left, order)
            scored = {w: raw[w] for w in order[:LIMIT] if w in raw}
            result = order
            if self.rerank and len(scored) > 1:
                s = dict(scored)
                if self.learn and boost and boost[0] in s:
                    s[boost[0]] += boost[1]
                result = self.rerank(order, s)
            rank = result.index(wanted)
            out.append((wanted, rank))
            # skk-zenz--learn-choice
            if self.learn and self.rerank and len(scored) > 1 and rank > 0:
                best = max(scored.values())
                boost = ((wanted, best - scored[wanted])
                         if math.isfinite(scored.get(wanted, -math.inf)) and scored[wanted] < best
                         else None)
            # SKK's learning
            personal = [wanted] + [w for w in personal if w != wanted]
        return out


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--cases", default=str(Path(__file__).with_suffix(".json")))
    p.add_argument("--jisyo", required=True, help="SKK dictionary, e.g. SKK-JISYO.L")
    p.add_argument("--server", default=str(ROOT / "build" / "zenz-server"))
    p.add_argument("--model", default=str(ROOT / "models" / "zenz-v3.2-small-Q5_K_M.gguf"))
    p.add_argument("--threshold", type=float, default=1.0)
    p.add_argument("--weight", type=float, default=1.0)
    p.add_argument("--no-context", action="store_true", help="score without left context")
    args = p.parse_args()

    cases = json.loads(Path(args.cases).read_text(encoding="utf-8"))
    jisyo = load_jisyo(args.jisyo)
    server = Server(args.server, args.model)

    def scorer(kana):
        cache = {}

        def score(left, words):
            left = "" if args.no_context else left
            words = [w for w in words if scorable(w)][:LIMIT]
            missing = [w for w in words if (left, w) not in cache]
            if missing:
                for w, x in zip(missing, server.score(kana, left, "", missing)):
                    cache[(left, w)] = x if x is not None else -math.inf
            return {w: cache[(left, w)] for w in words}
        return score

    methods = [
        Method("dictionary", None, False),
        Method(f"promote θ={args.threshold:g}",
               lambda o, s: promote(o, s, args.threshold), False),
        Method(f"promote θ={args.threshold:g} +learn",
               lambda o, s: promote(o, s, args.threshold), True),
        Method(f"mix β={args.weight:g}", lambda o, s: mix(o, s, args.weight), False),
        Method(f"mix β={args.weight:g} +learn", lambda o, s: mix(o, s, args.weight), True),
    ]
    stats = defaultdict(lambda: defaultdict(int))
    rows = []
    for case in cases:
        score = scorer(case["kana"])
        line = {}
        for m in methods:
            ranks = m.run(case, jisyo, score)
            line[m.name] = ranks
            for wanted, rank in ranks:
                group = "user" if wanted == case["word"] else "rival"
                st = stats[(m.name, group)]
                st["n"] += 1
                st["top1"] += rank == 0
                st["spc"] += rank
        rows.append((case, line))

    print(f"left context: {'none' if args.no_context else 'as given'}\n")
    print(f"{'method':24} {'user word top-1':>16} {'extra SPC':>9}"
          f" {'rival top-1':>12} {'extra SPC':>9}")
    for m in methods:
        u, r = stats[(m.name, "user")], stats[(m.name, "rival")]
        print(f"{m.name:24} {u['top1']:>9}/{u['n']:<6} {u['spc']:>9}"
              f" {r['top1']:>6}/{r['n']:<5} {r['spc']:>9}")

    print("\nRank of the wanted word per use (rivals in brackets):")
    for case, line in rows:
        print(f"\n{case['kana']} {case['word']} ({case['note']})")
        for m in methods[1:]:
            cells = [f"[{rank}]" if wanted != case["word"] else str(rank)
                     for wanted, rank in line[m.name]]
            print(f"  {m.name:24} {' '.join(cells)}")


if __name__ == "__main__":
    main()
