#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["fugashi", "unidic-lite"]
# ///
"""Offline evaluation of reranking SKK dictionary candidates with zenz scores.

  collect  Extract (left context, reading, written form) from Japanese text,
           look the reading up in SKK dictionaries, score the candidates with
           zenz-server (with and without the left context), and write JSONL.
  report   Compare candidate orders on a collected JSONL file.

Example:

  uv run scripts/eval_rerank.py collect -o eval.jsonl \\
      --jisyo ~/.skk-jisyo --jisyo SKK-JISYO.L posts/*.org
  uv run scripts/eval_rerank.py report eval.jsonl

The first --jisyo is treated as the personal dictionary.  Orders are compared
on "ambiguous" instances only: the written form is among at least two
candidates.  Text files may be Org or Markdown; code blocks, keywords,
drawers, and tables are skipped.
"""

import argparse
import json
import math
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEFT_CHARS = 40
KANJI = re.compile(r"[㐀-鿿豈-﫿々〆ヶ]")
HIRAGANA_ONLY = re.compile(r"^[ぁ-ゖー]+$")
JAPANESE_ONLY = re.compile(r"^[ぁ-ゖァ-ヺー㐀-鿿豈-﫿々〆ヶ]+$")
MAX_SPAN = 4
MAX_SCORED = 64

# First okurigana kana -> SKK okuri character.
OKURI_CHAR = {}
for chars, c in [("あぁ", "a"), ("いぃ", "i"), ("うぅ", "u"), ("えぇ", "e"), ("おぉ", "o"),
                 ("かきくけこ", "k"), ("がぎぐげご", "g"), ("さしすせそ", "s"),
                 ("ざじずぜぞ", "z"), ("たちつてとっ", "t"), ("だぢづでど", "d"),
                 ("なにぬねのん", "n"), ("はひふへほ", "h"), ("ばびぶべぼ", "b"),
                 ("ぱぴぷぺぽ", "p"), ("まみむめも", "m"), ("やゆよゃゅょ", "y"),
                 ("らりるれろ", "r"), ("わを", "w")]:
    for ch in chars:
        OKURI_CHAR[ch] = c


def to_hiragana(s):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in s)


# ---------------------------------------------------------------- text


def clean_lines(text):
    """Yield prose lines of an Org or Markdown document, markup removed."""
    in_block = False
    in_front = False
    for i, line in enumerate(text.splitlines()):
        s = line.strip()
        low = s.lower()
        if i == 0 and s == "---":
            in_front = True
            continue
        if in_front:
            in_front = s != "---"
            continue
        if low.startswith(("#+begin_src", "#+begin_example", "```")) and not in_block:
            in_block = True
            continue
        if in_block:
            if low.startswith(("#+end_src", "#+end_example", "```")):
                in_block = False
            continue
        if not s or s.startswith(("#+", "|", ":")) or low.startswith("#+"):
            continue
        s = re.sub(r"^\*+\s+", "", s)          # Org headings
        s = re.sub(r"^#+\s+", "", s)           # Markdown headings
        s = re.sub(r"^(?:[-+*]|\d+[.)])\s+", "", s)
        s = re.sub(r"\[\[[^\]]*\]\[([^\]]*)\]\]", r"\1", s)
        s = re.sub(r"\[\[[^\]]*\]\]", "", s)
        s = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", s)
        s = re.sub(r"https?://\S+", "", s)
        s = re.sub(r"(?<!\w)[=~`*/+_]([^=~`*/+_]+)[=~`*/+_](?!\w)", r"\1", s)
        if s:
            yield s


# ---------------------------------------------------------------- dictionaries


def load_jisyo(path):
    """Return {key: [candidate, ...]} with annotations and okuri blocks removed."""
    raw = Path(path).expanduser().read_bytes()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("euc_jis_2004")
    entries = {}
    for line in text.splitlines():
        line = line.rstrip("\r")
        if not line or line.startswith(";"):
            continue
        key, sep, rest = line.partition(" /")
        if not sep:
            continue
        rest = re.sub(r"\[[^\]]*\]/", "", rest)
        words = []
        for w in rest.split("/"):
            w = w.split(";", 1)[0] if not w.startswith("(") else w
            if w and w not in words:
                words.append(w)
        if words:
            entries[key] = words
    return entries


def merge_candidates(dicts, key):
    """Return per-dictionary candidate lists for `key`."""
    return [d.get(key, []) for d in dicts]


# ---------------------------------------------------------------- extraction


def extract(lines, dicts, tagger, right_context):
    """Yield instances found in `lines`, which form one document."""
    doc = ""
    for line in lines:
        if doc:
            doc += "\n"
        start = len(doc)
        doc += line
        words = []
        pos = 0
        for w in tagger(line):
            idx = line.find(w.surface, pos)
            if idx < 0:
                break
            words.append((idx, w))
            pos = idx + len(w.surface)
        i = 0
        while i < len(words):
            inst, used = match_nashi(words, i, dicts)
            if inst is None:
                inst, used = match_ari(words, i, dicts)
            if inst is None:
                i += 1
                continue
            begin = start + words[i][0]
            end_in_line = words[i + used - 1][0] + len(words[i + used - 1][1].surface)
            inst["left"] = doc[max(0, begin - LEFT_CHARS):begin]
            inst["right"] = line[end_in_line:end_in_line + LEFT_CHARS] if right_context else ""
            yield inst
            i += used


def word_kana(w):
    kana = getattr(w.feature, "kana", None)
    return to_hiragana(kana) if kana and kana != "*" else None


def match_nashi(words, i, dicts):
    for span in range(min(MAX_SPAN, len(words) - i), 0, -1):
        ws = [w for _, w in words[i:i + span]]
        # Words must be adjacent (no skipped spaces).
        if any(words[i + k][0] + len(ws[k].surface) != words[i + k + 1][0]
               for k in range(span - 1)):
            continue
        surface = "".join(w.surface for w in ws)
        kanas = [word_kana(w) for w in ws]
        if None in kanas or not KANJI.search(surface) or not JAPANESE_ONLY.match(surface):
            continue
        reading = "".join(kanas)
        if not HIRAGANA_ONLY.match(reading):
            continue
        lists = merge_candidates(dicts, reading)
        if any(surface in l for l in lists):
            return {"kind": "nashi", "kana": reading, "gold": surface, "okuri": "",
                    "lists": lists}, span
    return None, 0


def match_ari(words, i, dicts):
    w = words[i][1]
    if w.feature.pos1 not in ("動詞", "形容詞"):
        return None, 0
    m = re.match(r"^([㐀-鿿豈-﫿々]+)([ぁ-ゖ]+)$", w.surface)
    reading = word_kana(w)
    if not m or not reading:
        return None, 0
    stem, okuri = m.groups()
    if not reading.endswith(okuri) or len(reading) == len(okuri) or okuri[0] not in OKURI_CHAR:
        return None, 0
    key = reading[:-len(okuri)] + OKURI_CHAR[okuri[0]]
    lists = merge_candidates(dicts, key)
    if not any(stem in l for l in lists):
        return None, 0
    return {"kind": "ari", "kana": reading, "gold": stem, "okuri": okuri, "lists": lists}, 1


# ---------------------------------------------------------------- scoring


class Server:
    def __init__(self, program, model):
        cmd = [program] + (["--model", model] if model else [])
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     text=True, encoding="utf-8", bufsize=1)
        hello = json.loads(self.proc.stdout.readline())
        if hello.get("protocol") != 2:
            sys.exit(f"unsupported server: {hello}")
        self.next_id = 0

    def score(self, kana, left, right, texts):
        self.next_id += 1
        req = {"id": self.next_id, "op": "score", "kana": kana, "left": left,
               "right": right, "candidates": texts}
        self.proc.stdin.write(json.dumps(req, ensure_ascii=False) + "\n")
        resp = json.loads(self.proc.stdout.readline())
        if "error" in resp:
            raise RuntimeError(resp["error"])
        return resp["scores"]


def scorable(word):
    return not word.startswith("(") and "#" not in word


def cmd_collect(args):
    import fugashi

    tagger = fugashi.Tagger()
    dicts = [load_jisyo(p) for p in args.jisyo]
    server = Server(args.server, args.model)
    n = 0
    with open(args.output, "w", encoding="utf-8") as out:
        for path in args.files:
            lines = list(clean_lines(Path(path).read_text(encoding="utf-8")))
            for inst in extract(lines, dicts, tagger, args.right_context):
                union = []
                for l in inst["lists"]:
                    union += [w for w in l if w not in union]
                words = [w for w in union if scorable(w)][:MAX_SCORED]
                texts = [w + inst["okuri"] for w in words]
                inst["file"] = str(path)
                inst["scores"] = dict(zip(words, server.score(
                    inst["kana"], inst["left"], inst["right"], texts)))
                inst["scores0"] = dict(zip(words, server.score(inst["kana"], "", "", texts)))
                out.write(json.dumps(inst, ensure_ascii=False) + "\n")
                n += 1
    print(f"{n} instances written to {args.output}", file=sys.stderr)


# ---------------------------------------------------------------- report


def rerank(order, scores, key_fn, top_k):
    """Reorder the first `top_k` words of `order` by key_fn(word, rank) (higher
    first).  Unscorable words keep their positions."""
    head, tail = order[:top_k], order[top_k:]
    movable = [(i, w) for i, w in enumerate(head) if w in scores]
    ranked = sorted(movable, key=lambda iw: -key_fn(iw[1], iw[0]))
    result = list(head)
    for (slot, _), (_, w) in zip(movable, ranked):
        result[slot] = w
    return result + tail


def methods(betas, thetas, top_k):
    ms = {"dict": lambda order, s: order,
          "zenz": lambda order, s: rerank(order, s, lambda w, r: s[w], top_k)}
    for b in betas:
        ms[f"mix b={b:g}"] = (lambda b: lambda order, s: rerank(
            order, s, lambda w, r: s[w] - b * math.log1p(r), top_k))(b)
    for t in thetas:
        def promote(order, s, t=t):
            head = [w for w in order[:top_k] if w in s]
            if not head or order[0] not in s:
                return order
            best = max(head, key=lambda w: s[w])
            if best != order[0] and s[best] - s[order[0]] > t:
                return [best] + [w for w in order if w != best]
            return order
        ms[f"promote t={t:g}"] = promote
    return ms


def cmd_report(args):
    insts = [json.loads(l) for l in open(args.input, encoding="utf-8")]
    betas = [float(x) for x in args.betas.split(",")]
    thetas = [float(x) for x in args.thetas.split(",")]
    ms = methods(betas, thetas, args.top_k)

    def base_orders(inst):
        lists = inst["lists"]
        union = []
        for l in lists:
            union += [w for w in l if w not in union]
        return {"L": lists[-1], "personal+L": union}

    for base in ("L", "personal+L"):
        for ctx in ("scores", "scores0"):
            stats = defaultdict(lambda: defaultdict(float))
            for inst in insts:
                order = base_orders(inst)[base]
                if inst["gold"] not in order or len(order) < 2:
                    continue
                s = inst[ctx]
                base_ok = order[0] == inst["gold"]
                for name, fn in ms.items():
                    new = fn(order, s)
                    rank = new.index(inst["gold"])
                    for group in ("all", inst["kind"]):
                        st = stats[(group, name)]
                        st["n"] += 1
                        st["top1"] += rank == 0
                        st["mrr"] += 1 / (rank + 1)
                        st["fixed"] += (not base_ok) and rank == 0
                        st["broken"] += base_ok and rank != 0
            label = "with left context" if ctx == "scores" else "without context"
            print(f"\n## base order: {base}, zenz {label}")
            print(f"{'group':6} {'method':14} {'n':>5} {'top1':>7} {'MRR':>7} {'fixed':>6} {'broken':>6}")
            for (group, name), st in sorted(stats.items(), key=lambda kv: (kv[0][0] != "all", kv[0][0])):
                n = st["n"]
                print(f"{group:6} {name:14} {int(n):5} {st['top1'] / n:7.3f} {st['mrr'] / n:7.3f}"
                      f" {int(st['fixed']):6} {int(st['broken']):6}")
    if args.examples:
        show_examples(insts, ms, args)


def show_examples(insts, ms, args):
    """Print instances where the chosen method changes the top candidate."""
    fn = ms[args.examples]
    print(f"\n## examples: {args.examples} (L order, with context)")
    for inst in insts:
        order = inst["lists"][-1]
        if inst["gold"] not in order or len(order) < 2:
            continue
        new = fn(order, inst["scores"])
        if new[0] != order[0]:
            mark = "+" if new[0] == inst["gold"] else ("-" if order[0] == inst["gold"] else " ")
            print(f"{mark} …{inst['left'][-12:]}[{inst['kana']}] gold={inst['gold']}"
                  f" dict={order[0]} zenz={new[0]}".replace("\n", "⏎"))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("files", nargs="+")
    c.add_argument("-o", "--output", required=True)
    c.add_argument("--jisyo", action="append", required=True,
                   help="SKK dictionary; repeat, personal dictionary first")
    c.add_argument("--server", default=str(ROOT / "build" / "zenz-server"))
    c.add_argument("--model", default=str(ROOT / "models" / "zenz-v3.2-small-Q5_K_M.gguf"))
    c.add_argument("--right-context", action="store_true",
                   help="send the rest of the line as right context")
    r = sub.add_parser("report")
    r.add_argument("input")
    r.add_argument("--betas", default="0.5,1,2,4")
    r.add_argument("--thetas", default="0,1,2,4")
    r.add_argument("--top-k", type=int, default=20)
    r.add_argument("--examples", metavar="METHOD",
                   help='list top-1 changes of METHOD, e.g. "promote t=2"')
    args = p.parse_args()
    {"collect": cmd_collect, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    main()
