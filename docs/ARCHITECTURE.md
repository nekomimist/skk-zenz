# Architecture

Status: draft. Phase 0 findings are recorded in `ROADMAP.md`.

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
- The reading must be katakana; zenz-server converts hiragana.
- Like azooKey, zenz-server replaces ASCII spaces with U+3000 and removes
  newlines, because the tokenizer maps both to `[UNK]`. It does this before
  truncating the context so newlines do not use up the character budget.

## Decoding
- azooKey's `ZenzPureGreedyDecoder` produces a single greedy result.
- SKK expects several candidates, so zenz-server runs a beam search (n-best);
  beam width 1 is greedy decoding. It decodes the prompt once and shares the KV
  cache across beams: beams alternate between two banks of sequence IDs, and
  `llama_memory_seq_cp` tags the parent's cells for the child without copying
  data. This needs `kv_unified = true` and `n_seq_max = 2 * max beam width`.
- No BOS token is prepended. The GGUF sets `add_bos_token = false`, so azooKey's
  `add_bos: true` has no effect either.
- Search stops when n-best candidates have finished and no live beam can beat
  the n-th score (scores only decrease). Output is capped at the reading length
  plus 8 tokens.
- Candidates are sorted by total log-probability. Duplicate strings (the same
  text reached through different tokenizations) are removed. The server does
  not filter kana-only candidates; the client decides.

## Protocol
Running `zenz-server` without `--convert` or `--prompt` serves requests: one
JSON object per line in each direction, UTF-8. Requests are handled one at a
time, in order.

After the model loads, the server writes a hello line:
```json
{"hello": "zenz-server", "protocol": 1}
```
The client must check `protocol` against its own version. The server exits
with status 0 when stdin reaches EOF. If the model fails to load, the server
writes the reason to stderr and exits with a non-zero status before the hello.

Request:
```json
{"id": 1, "kana": "かいとう", "left": "試験問題の", "right": "", "n": 3}
```
- `id`: any JSON value, echoed back (null if missing).
- `kana`: the reading, required and non-empty. Hiragana is converted to katakana.
- `left`, `right`: optional context strings. The server trims them to 40
  characters.
- `n`: optional number of candidates, default 1, clamped to 1..8. The beam
  width equals `n` unless the server was started with `--beam`.

Response:
```json
{"id": 1, "candidates": ["解答", "回答", "解凍"], "scores": [-0.14, -2.07, -8.25]}
```
- `candidates` are best first; `scores` are total log-probabilities, in the
  same order. Fewer than `n` candidates may be returned.
- Errors: `{"id": 1, "error": "message"}`. A line that is not a JSON object gets
  `"id": null`.

Emacs 29 has native JSON support (`json-parse-string`, `json-serialize`), so
the client needs no extra dependency.

## SKK Integration

`skk-zenz-mode` (a global minor mode) installs everything below and removes it
again when disabled.

### Trigger policy
Two entries in `skk-search-prog-list`:

- (a) Long readings: `(skk-zenz-search :long)` at the head fires when the
  reading has at least `skk-zenz-min-length` characters (default 10; nil
  disables it). zenz candidates come first for long phrases (the approach that
  worked with Sumibi). It requests `skk-zenz-long-candidates` (default 3).
- (b) Fallback: `(skk-zenz-search :fallback)` at the tail fires for other
  readings. `skk-search` stops at the first program that returns candidates and
  keeps the rest in `skk-current-search-prog-list`; later programs run only
  when the user steps past the last candidate. zenz candidates therefore appear
  after the dictionary candidates and before dictionary registration. It
  requests `skk-zenz-fallback-candidates` (default 5). It skips long readings
  when entry (a) is in `skk-search-prog-list`, so a reading goes to zenz at
  most once.

A reading is sent only if it matches `skk-zenz-reading-regexp` (hiragana, ー,
and a few punctuation marks) and `skk-okuri-char` is nil. Okuri-ari and abbrev
readings contain ASCII letters and never match.

### Context extraction
- Left context: up to `skk-zenz-context-length` (default 40) characters
  before `skk-henkan-start-point`, excluding the ▽/▼ marker just before it.
  It may span lines; the server removes newlines.
- Right context: up to the same number of characters after
  `skk-henkan-end-point` (or point), stopping at the end of the line, because
  text on following lines is often unrelated.

### Candidate filtering
The client drops candidates that are empty, equal to the reading, already in
`skk-henkan-list`, or duplicated. It also drops candidates that SKK would
misinterpret: `;` starts an annotation, a string that looks like a Lisp form
`(...)` would be evaluated, and newlines or U+FFFD indicate broken output.
Kept candidates get the annotation `;zenz` (`skk-zenz-annotation`, nil for
none).

### Learning exclusion
- DDSKK's `skk-search-excluding-word-pattern-function` hook receives the
  confirmed word (with its annotation). If a hook function returns non-nil, the
  word is not added to the personal dictionary. The hook is called from
  `skk-update-jisyo-p`, while `skk-henkan-key` is still set.
- skk-zenz records the reading and the words it returned for the last zenz
  search (buffer-local). A confirmed word is excluded if the reading matches,
  the word is one of those, and its annotation is `skk-zenz-annotation`. With
  annotations on, the same word from a dictionary has a different (or no)
  annotation and is learned normally. With annotations off, any matching word
  is excluded.

### Process management and failures
- The server starts on the first zenz search and must send a compatible hello
  within `skk-zenz-startup-timeout` (5 s).
- Each search waits up to `skk-zenz-timeout` (1 s). On timeout the search
  returns nil and the late reply is discarded. The server still finishes the
  old request first, so the next search may be delayed.
- If the server cannot start, reports a different protocol version, or exits,
  the failure is shown in the echo area and no restart is attempted for
  `skk-zenz-retry-interval` (30 s). Conversions continue without zenz in the
  meantime. `M-x skk-zenz-restart` clears this state.
- `json-serialize` returns a unibyte UTF-8 string on Emacs 30 and later; the
  client decodes it before sending so the pipe's `utf-8-unix` coding encodes
  it exactly once.

## llama.cpp Dependency
- Upstream llama.cpp cannot load zenz models: the GGUF declares
  `tokenizer.ggml.pre = gpt2-small-japanese-char`, which upstream does not know.
- The GGUF also declares wrong special token IDs (bos=1, eos=2), while the
  vocabulary has `[UNK]`=0, `[PAD]`=1, `<s>`=2, `</s>`=3. With the declared IDs,
  generation would not stop at `</s>`.
- `azooKey/llama.cpp` branch `azookey/b9637-compat` is upstream tag `b9637` plus
  one commit that:
  - adds the `gpt2-small-japanese-char` pre-tokenizer type,
  - maps the newline and space byte symbols to `[UNK]`,
  - overrides the special token IDs (unk=0, pad=1, bos=2, eos=3).
- Decision: pin that branch as a git submodule. If the fork stops tracking
  upstream, carry the same patch on top of upstream instead.
- The vocabulary is byte-level BPE with 6000 tokens. Each U+EExx tag encodes
  as three byte tokens; this matches how azooKey tokenizes prompts.
