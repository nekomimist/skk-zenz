# Architecture

Status: draft. Sections marked **(to verify)** depend on Phase 0 results in
`ROADMAP.md`.

## Goals
- Convert readings that SKK dictionaries handle poorly (long phrases, unknown
  words) with zenz v3.2, running locally on CPU.
- No network access, no API cost, no data leaving the machine.
- Keep SKK's normal dictionary behavior for everything else.

## Non-goals (for now)
- Replacing SKK dictionaries.
- Okuri-ari (送りあり) conversion.
- GPU inference. The model is small (95M parameters, ~74 MB at Q5_K_M), and CPU
  inference is fast enough.

## Components

```
Emacs (skk-zenz.el)                             zenz-server (C++)
  search function in skk-search-prog-list
    ├ reading + left/right context from buffer ── JSON Lines over pipe ──▶ build prompt
    ├ wait synchronously with timeout          ◀── candidates ────────── n-best decode (llama.cpp)
    └ exclude zenz candidates from learning
```

### zenz-server
- Single binary, statically linked with libllama.
- Loads the model once at startup and serves requests until stdin closes.
- Also provides a one-shot CLI mode for debugging and benchmarks.

### skk-zenz.el
- Starts `zenz-server` lazily on first use and restarts it if it dies.
- Sends a request and waits with `accept-process-output` up to a timeout. On
  timeout or error, it returns nil so SKK continues normally.

## Model and Prompt Format
Model: `Miwa-Keita/zenz-v3.2-small-gguf` (GPT-2 architecture, character-level
Japanese vocabulary, Apache-2.0).

Prompt (from AzooKeyKanaKanjiConverter `ZenzPromptBuilder.swift`):

```
[conditions] U+EE02 <left context> U+EE07 <right context> U+EE00 <katakana reading> U+EE01
```

- The model generates the converted text after U+EE01 until EOS.
- The left context is truncated to its last 40 characters, the right context to
  its first 40 characters (azooKey defaults).
- Omit the U+EE02 / U+EE07 sections when the corresponding context is empty.
- Optional conditions: U+EE03 profile, U+EE04 topic, U+EE05 style, U+EE06
  preference (each up to 25 characters). Not used initially.
- The reading must be katakana; the client or server converts hiragana.

## Decoding
- azooKey's `ZenzPureGreedyDecoder` produces a single greedy result.
- SKK expects several candidates, so zenz-server runs a small beam search
  (n-best). It evaluates the prompt once and shares the KV cache across beams
  (for example with `llama_memory_seq_cp`).
- Duplicates and candidates identical to the reading are removed.

## Protocol (draft)
One JSON object per line in each direction, UTF-8.

Request:
```json
{"id": 1, "kana": "きょうはいいてんき", "left": "...", "right": "...", "n": 5}
```

Response:
```json
{"id": 1, "candidates": ["今日はいい天気", "..."]}
```

- The server sends a hello line with its protocol version at startup.
- Errors: `{"id": 1, "error": "message"}`.
- Emacs 29 has native JSON support (`json-parse-string`, `json-serialize`), so the
  client needs no extra dependency.

## SKK Integration

### Trigger policy
Two entries, both configurable:

- (a) Long readings: At the head of `skk-search-prog-list`, a search that only
  fires when the reading has at least `skk-zenz-min-length` characters (default
  10). zenz candidates come first for long phrases (the approach that worked with
  Sumibi).
- (b) Fallback: At the tail of `skk-search-prog-list`, a search that fires for any
  okuri-nasi reading. DDSKK consults later programs only after the earlier
  candidates are exhausted, so zenz candidates appear after the dictionary
  candidates and before dictionary registration. **(to verify)**

Only okuri-nasi conversions are handled. For okuri-ari, the search returns nil.

### Context extraction
- Left context: text before the henkan start point, limited to the current
  paragraph (or line) and to 40 characters.
- Right context: text after point, with the same limits.
- Text inside the ▽ region is the reading, not context.

### Learning exclusion
- DDSKK's `skk-search-excluding-word-pattern-function` hook receives the
  confirmed word. If a hook function returns non-nil, the word is not added to
  the personal dictionary. The hook is called from `skk-update-jisyo-p`.
- skk-zenz records the candidates it returned for the current conversion and
  excludes a confirmed word only if it came from zenz and not from a dictionary.
- Candidates are annotated (for example `[zenz]`) so the user can see where they
  came from.

## llama.cpp Dependency
- zenz models need a tokenizer fix. As of 2026-07, `azooKey/llama.cpp` branch
  `azookey/b9637-compat` is upstream tag `b9637` plus one commit that:
  - adds the `gpt2-small-japanese-char` pre-tokenizer type,
  - maps the newline and space byte symbols to `[UNK]`,
  - fixes special token IDs (unk=0, pad=1, bos=2, eos=3).
- Plan: pin that branch as a git submodule. Carrying the patch on top of upstream
  is the fallback if the fork stops tracking upstream. **(to verify)**
