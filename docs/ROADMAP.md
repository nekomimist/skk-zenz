# Roadmap

Design details live in `ARCHITECTURE.md`. This file tracks phases, tasks, and open
questions.

## Phase 0: Feasibility spike
Build and measure outside the repository; record conclusions here and in
`ARCHITECTURE.md`.

- [ ] Build `azooKey/llama.cpp` `azookey/b9637-compat` and upstream `b9637` (CPU only).
- [ ] Download `zenz-v3.2-small` Q5_K_M and inspect `tokenizer.ggml.pre` and the
      special tokens.
- [ ] Compare tokenization between the fork and upstream on sample prompts.
- [ ] Run greedy conversion with a sample prompt, with and without context.
- [ ] Measure model load time and per-request latency on Linux x86_64.
- [ ] Decide: fork as submodule vs upstream plus patch.

## Phase 1: One-shot CLI
- [ ] CMake project with llama.cpp as a submodule, static link.
- [ ] Prompt builder, hiragana-to-katakana conversion.
- [ ] Greedy decoding.
- [ ] n-best beam search with shared KV cache.
- [ ] C++ tests (prompt builder, katakana conversion); opt-in model tests.
- [ ] Top-level `Makefile` with `build` and `test` targets.

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
- Does DDSKK call tail programs in `skk-search-prog-list` only after earlier
  candidates are exhausted, as trigger (b) assumes?
- How should the client recognize zenz candidates at confirmation time when a
  dictionary returned the same word?
- Is the right context useful in practice for SKK input, where text after point
  is often empty?
