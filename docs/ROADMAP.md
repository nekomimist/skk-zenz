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
- [ ] Greedy decoding.
- [ ] n-best beam search with shared KV cache.
- [ ] C++ tests (prompt builder, katakana conversion); opt-in model tests.
- [x] Top-level `Makefile` with `build` and `test` targets.

## Phase 2: Resident server
- [ ] JSON Lines protocol over stdin/stdout with hello/version line.
- [ ] Error responses, graceful shutdown on EOF.
- [ ] Latency benchmark of repeated requests.

## Phase 3: Emacs client
- [ ] Process management (lazy start, restart, shutdown).
- [ ] Synchronous request with timeout.
- [ ] Search functions for trigger (a) long readings and (b) fallback.
- [ ] Context extraction from the buffer.
- [ ] Learning exclusion via `skk-search-excluding-word-pattern-function`.
- [ ] Candidate annotation.
- [ ] ERT tests with a fake server.

## Phase 4: Docs and packaging
- [ ] `README.md`: build, model download, configuration examples.
- [ ] `CHANGELOG.md`.
- [ ] Model download helper script.

## Phase 5: Tuning
- [ ] Context length, beam width, `skk-zenz-min-length`, timeout.
- [ ] Compare quality against the earlier Sumibi setup.

## Later
- Linux ARM64 support.
- Okuri-ari conversion.
- Asynchronous prefetch while typing in ▽ mode.
- Rerank SKK dictionary candidates by zenz likelihood (Zenzai-style candidate
  evaluation).
- v3 condition tags (profile, topic, style).

## Open Questions
- How should the client recognize zenz candidates at confirmation time when a
  dictionary returned the same word?
- Is the right context useful in practice for SKK input, where text after point
  is often empty?
