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
- [ ] Context length, beam width, `skk-zenz-min-length`, timeout.
- [ ] Compare quality against the earlier Sumibi setup.

## Phase 6: Rerank dictionary candidates
Score SKK dictionary candidates with zenz (the `score` op) and reorder them by
context, like Zenzai's candidate evaluation. Design: `ARCHITECTURE.md`.

- [x] `score` op in zenz-server (teacher forcing, shared prompt KV cache).
- [x] Offline evaluation (`scripts/eval_rerank.py`).
- [ ] Client: a search program that merges dictionary programs and reranks.
- [ ] Okuri-ari readings (stem + okurigana is scored as one text).

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
- Broken cases are mostly equally valid variants (稼動 → 稼働) or rare words
  (逃避 → 頭皮, 代替 → 大体).
- Caveats: the corpus is small and single-author, the evaluator's
  segmentation turns some okuri-ari words into okuri-nashi entries (かき →
  書き), and the texts may overlap with the model's training data.

## Later
- Linux ARM64 support.
- Okuri-ari conversion.
- Asynchronous prefetch while typing in ▽ mode.
- v3 condition tags (profile, topic, style).

## Open Questions
- How should the client recognize zenz candidates at confirmation time when a
  dictionary returned the same word?
- Is the right context useful in practice for SKK input, where text after point
  is often empty?
