# Roadmap

Design details live in `ARCHITECTURE.md`. This file tracks phases, tasks, and open
questions.

## Phase 0: Feasibility spike (done)
- [x] Build `azooKey/llama.cpp` `azookey/b9637-compat` and upstream `b9637` (CPU only).
- [x] Download `zenz-v3.2-small` Q5_K_M and inspect `tokenizer.ggml.pre` and the
      special tokens.
- [x] Compare tokenization between the fork and upstream on sample prompts.
- [x] Run greedy conversion with a sample prompt, with and without context.
- [x] Measure model load time and per-request latency on Linux x86_64.
- [x] Decide: fork as submodule vs upstream plus patch.
- [x] Check how DDSKK walks `skk-search-prog-list` and calls the learning
      exclusion hook.

Findings (2026-09-27, WSL2 on x86_64 with 32 hardware threads, `llama-simple` defaults, greedy):

- Upstream `b9637` fails to load the model; the fork is required. See
  `ARCHITECTURE.md` for the reasons and the decision.
- Context changes results as expected: カイトウ → 回答 (no context), 解答
  (left: 試験問題の), 解凍 (left: 冷凍食品を電子レンジで).
- Latency for a 26-token prompt and 7 output tokens: model load 34 ms, prompt
  eval 19 ms, generation 16 ms. A whole one-shot process takes about 60 ms
  wall time and 95 MB RSS.
- A resident server saves the load time and process startup on every
  conversion, so it stays the plan. A one-shot fallback would still be usable.
- Trigger (b) works as assumed: `skk-search` keeps unused programs in
  `skk-current-search-prog-list` and resumes them when candidates run out.

## Phase 1: One-shot CLI
- [x] CMake project with llama.cpp as a submodule, static link.
- [x] Prompt builder, hiragana-to-katakana conversion.
- [x] Greedy decoding.
- [x] n-best beam search with shared KV cache.
- [x] C++ tests (prompt builder, katakana conversion); opt-in model tests.
- [x] Top-level `Makefile` with `build` and `test` targets.

Findings (warm, `zenz-server --bench 20`, same machine as Phase 0):

| Reading | Candidates | 1 thread | 2 threads | 4 threads | 8 threads |
|---|---|---|---|---|---|
| 22 kana, 6-char left context | 1 (greedy) | 149 ms | 89 ms | 60 ms | 57 ms |
| same | 3 | 249 ms | 157 ms | 89 ms | 74 ms |
| same | 5 | 368 ms | 207 ms | 121 ms | 98 ms |
| きしゃ | 1 / 5 | | | 14 / 27 ms | |

- The default is 4 threads; more threads help little.
- Beam search costs roughly linearly in the beam width, so trigger (a) may want
  fewer candidates than trigger (b). Revisit in Phase 5.
- Lower beams sometimes produce broken text (機械学習のモデルを組んれんする);
  consider filtering in Phase 5.

## Phase 2: Resident server (done)
- [x] JSON Lines protocol over stdin/stdout with hello/version line.
- [x] Error responses, graceful shutdown on EOF.
- [x] Latency benchmark of repeated requests (`scripts/bench_server.py`).

Findings: the hello line arrives about 30 ms after start. Round trips match the
`--bench` numbers above (JSON overhead is negligible): for example 20 ms for
かいとう and 61 ms for a 22-kana reading with n=1, and 37 ms / 126 ms with
n=5. Score gaps look useful for dropping weak candidates (高校の教師 vs
高校の今日し); see Phase 5.

## Phase 3: Emacs client (done)
- [x] Process management (lazy start, restart, shutdown).
- [x] Synchronous request with timeout.
- [x] Search functions for trigger (a) long readings and (b) fallback.
- [x] Context extraction from the buffer.
- [x] Learning exclusion via `skk-search-excluding-word-pattern-function`.
- [x] Candidate annotation.
- [x] ERT tests with a fake server, including a DDSKK integration test that
      types keys in `skk-mode`.

## Phase 4: Docs and packaging (done)
- [x] `README.md`: build, model download, configuration examples.
- [x] `CHANGELOG.md`.
- [x] Model download helper (`make model`, pinned revision and SHA-256).
- [x] Check Emacs 29: byte-compiles without warnings and passes ERT on 29.4.

## Phase 5: Tuning
- [x] Offline evaluation of conversion (`scripts/eval_convert.py`,
      `zenz-server --max-context`).
- [x] Candidates for long readings: `skk-zenz-long-candidates` 3 → 5.
- [x] Keep `skk-zenz-min-length` (10) and `skk-zenz-timeout` (1.0 s).
- [ ] Context length: keep 40, and let `skk-zenz-context-length` above 40
      take effect.
- [ ] Drop candidates that trail the best by a large score gap.
- [ ] Usage log (opt-in, local only) to check the offline findings against
      real input.
- [ ] Compare quality against the earlier Sumibi setup.

Findings (2026-10-03, same machine as Phase 0, 4 threads). Corpora: the 12
blog posts used in Phase 6, cut into 1168 phrases of 1 to 6 bunsetsu (as
typed for zenz-first conversion) and 1163 words (the noun part of each
bunsetsu, as typed for ordinary SKK conversion); and the 200 items of
AJIMEE-Bench (Wikipedia-based, curated readings and acceptable outputs).
Dictionaries: personal, then SKK-JISYO.L.

Top-1 by left context length (n=5):

| Context | Blog phrases | Blog words | AJIMEE | Mean ms (phrases) |
|---|---|---|---|---|
| 0 | 0.810 | 0.825 | 0.800 | 74 |
| 10 | 0.839 | 0.911 | 0.845 | 81 |
| 20 | 0.846 | 0.919 | 0.835 | 86 |
| 40 | 0.849 | 0.932 | 0.845 | 101 |
| 80 | 0.860 | 0.936 | 0.845 | 127 |

- Ten characters give most of the gain. 80 adds about one point on blog
  phrases for 26 ms; AJIMEE contexts are shorter than 40, so it gains
  nothing there. The server caps context at 40 by default, so a client
  `skk-zenz-context-length` above 40 currently has no effect.

Candidate count (left context 40), for phrases of 10 or more kana:

| n | Blog: in n-best | Mean / p95 / max ms | AJIMEE: in n-best | Mean / p95 / max ms |
|---|---|---|---|---|
| 1 | 0.770 | 77 / 103 / 143 | 0.831 | 86 / 188 / 311 |
| 3 | 0.959 | 106 / 150 / 236 | 0.921 | 135 / 309 / 520 |
| 5 | 0.987 | 133 / 194 / 310 | 0.938 | 181 / 425 / 695 |
| 8 | 0.994 | 171 / 256 / 409 | 0.949 | 246 / 585 / 921 |

- Top-1 does not depend on the beam width (0.847 to 0.850 on blog
  phrases). Wider beams only add correct answers further down.
- Most top-1 misses on blog phrases are spelling variants of the
  author's style (気付く → 気づく, 時 → とき, ほう → 方, わりと → 割と); real
  errors (最速級 → 最速急) are few.
- The slowest requests are long AJIMEE readings with punctuation; n=5 stays
  under 0.7 s, within `skk-zenz-timeout` (1.0 s).

`skk-zenz-min-length` (blog words, left context 40, rerank `promote` θ=1):

| Reading length | Words | In dictionary | Dictionary top-1 | zenz top-1 (n=3) |
|---|---|---|---|---|
| 1-3 | 516 | 514 | 0.982 | 0.885 |
| 4-5 | 458 | 437 | 0.991 | 0.982 |
| 6-7 | 114 | 55 | 0.982 | 0.982 |
| 8-9 | 57 | 12 | 1.000 | 1.000 |
| 10+ | 18 | 0 | - | - |

- Dictionary first wins up to 5 kana; from 6 kana the two tie. No word of
  10 or more kana and no phrase of 8 or more kana had a dictionary entry,
  so above 6 the threshold mostly decides the candidate count (long vs
  fallback) rather than the order.

Score gap (n=5, left context 40): candidates after the first whose score
trails the first by more than T.

| T | Dropped (blog phrases) | Correct dropped | Dropped (blog words) | Correct dropped | Dropped (AJIMEE) | Correct dropped |
|---|---|---|---|---|---|---|
| 4 | 0.715 | 10 | 0.865 | 6 | 0.399 | 0 |
| 6 | 0.486 | 0 | 0.705 | 1 | 0.168 | 0 |
| 8 | 0.263 | 0 | 0.471 | 0 | 0.045 | 0 |

- At T=8 the dropped candidates are broken text (検索波, 個人てきには,
  利用して独立作成した); between 6 and 8 some are valid (格調, よく観る).

## Phase 6: Rerank dictionary candidates
Score SKK dictionary candidates with zenz (the `score` op) and reorder them by
context, like Zenzai's candidate evaluation. Design: `ARCHITECTURE.md`.

- [x] `score` op in zenz-server (teacher forcing, shared prompt KV cache).
- [x] Offline evaluation (`scripts/eval_rerank.py`).
- [x] Client: a search program that merges dictionary programs and reranks.
- [x] Okuri-ari readings (stem + okurigana is scored as one text).

Findings (2026-09-28, 12 blog posts from 2023 to 2026 by the user, 1376
instances where the written form is one of two or more dictionary
candidates; personal dictionary followed by SKK-JISYO.L; top 20 candidates
scored):

| Order | Top-1 with left context | Top-1 without context |
|---|---|---|
| Dictionary order | 0.894 | 0.894 |
| zenz score only | 0.982 (139 fixed, 18 broken) | 0.914 (98 fixed, 71 broken) |
| zenz − β·log(1+rank), β=1 | 0.988 (137 fixed, 7 broken) | 0.924 |
| Promote zenz's best if it wins by > θ=2 | 0.984 (128 fixed, 4 broken) | 0.941 (82 fixed, 17 broken) |

- The left context does most of the work. Without it, zenz alone breaks
  almost as many conversions as it fixes; the dictionary prior is needed.
- Okuri-ari instances (408 of them) gain as much as okuri-nashi ones
  (0.953 → 0.993 with β=1).
- Scoring cost grows with the candidate count: for こう (234 candidates), 10 /
  20 / 64 candidates take 30 / 37 / 78 ms. Scoring more than 20 did not
  change the result; 10 lost about 0.3 points.
- `promote` uses θ=1 rather than 2: with θ=2, 解答 (−0.14) did not replace
  回答 (−2.07) after 試験問題の. θ=1 scores 0.986 (8 broken) with context
  and 0.933 without.
- Okuri-ari with the real model: 手紙を → 書く, 絵を → 描く, but 注意を still
  prefers 書く (−0.57) over 欠く (−1.14).
- Code in the left context (2026-09-30; four lines of elisp from the posts
  followed by the text on the target's line, 40 characters in all):

  | Left context | Rerank top-1 (promote, θ=1) | Greedy conversion top-1 |
  |---|---|---|
  | Prose lines above, as written | 0.986 | 0.927 |
  | Code, then `;; ` and the target's line | 0.984 | 0.925 |
  | Code, then the target's line | 0.982 | 0.922 |
  | The target's line only | 0.984 | 0.910 |
  | None | 0.933 | 0.723 |

  Code costs at most half a point, and dropping it leaves a shorter context
  that converts worse. Skipping lines without Japanese and reaching further
  up for prose (`skk-zenz-context-skip-non-japanese`) aims at the first row.
- Broken cases are mostly equally valid variants (稼動 → 稼働) or rare words
  (逃避 → 頭皮, 代替 → 大体).
- Caveats: the corpus is small and single-author, the evaluator's
  segmentation turns some okuri-ari words into okuri-nashi entries (かき →
  書き), and the texts may overlap with the model's training data.

## Later
- Linux ARM64 support.
- Okuri-ari conversion by zenz (candidates beyond the dictionary).
- Asynchronous prefetch while typing in ▽ mode.
- v3 condition tags (profile, topic, style).

## Open Questions
- How should the client recognize zenz candidates at confirmation time when a
  dictionary returned the same word?
- Is the right context useful in practice for SKK input, where text after point
  is often empty?
