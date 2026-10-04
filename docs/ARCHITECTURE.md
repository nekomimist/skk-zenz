# Architecture

Status: draft. Phase 0 findings are recorded in `ROADMAP.md`.

## Goals
- Convert readings that SKK dictionaries handle poorly (long phrases, unknown
  words) with zenz v3.2, running locally on CPU.
- No network access, no API cost, no data leaving the machine.
- Keep SKK's normal dictionary behavior for everything else.

## Non-goals (for now)
- Replacing SKK dictionaries.
- Okuri-ari (送りあり) conversion by zenz. Okuri-ari dictionary candidates
  are reranked, though.
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
  its first 40 characters (azooKey defaults). `zenz-server --max-context C`
  changes both limits. The client passes it when `skk-zenz-context-length`
  is above 40.
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

## Scoring
- The `score` op computes, for each given text, the log-probability that the
  model produces exactly that text after the prompt: the sum of its token
  log-probabilities plus the end-of-sequence token (teacher forcing). The
  end-of-sequence term penalizes texts that cover only part of the reading.
- Texts go through the same space/newline substitution as the prompt and are
  tokenized on their own. A text the model would generate through a different
  tokenization gets the score of the canonical tokenization.
- The prompt is decoded once on sequence 0. The first token of every text is
  scored from the prompt's last logits. The texts are then decoded in chunks of
  up to 32 (`ModelOptions::score_batch`), each on its own sequence that shares
  the prompt's KV cells through `llama_memory_seq_cp`, with logits requested at
  every position. A chunk is one `llama_decode` call.
- Scoring five candidates for かいとう with a short left context takes about
  24 ms with 4 threads.

## Protocol
Running `zenz-server` without `--convert` or `--prompt` serves requests: one
JSON object per line in each direction, UTF-8. Requests are handled one at a
time, in order.

After the model loads, the server writes a hello line:
```json
{"hello": "zenz-server", "protocol": 2, "version": "0.1.0"}
```
The client must check `protocol` against its own version. `version` is the
server's build version (see Release Binaries) and is informational only.
`zenz-server --version` prints the same line and exits without loading a
model, so a client can check an executable cheaply. The server exits
with status 0 when stdin reaches EOF. If the model fails to load, the server
writes the reason to stderr and exits with a non-zero status before the hello.

Protocol 2 added the `score` op. A protocol 1 server would treat a score
request as a conversion, so the client refuses protocol 1 servers.

Conversion request:
```json
{"id": 1, "kana": "かいとう", "left": "試験問題の", "right": "", "n": 3}
```
- `id`: any JSON value, echoed back (null if missing).
- `op`: optional, `"convert"` (default) or `"score"`.
- `kana`: the reading, required and non-empty. Hiragana is converted to katakana.
- `left`, `right`: optional context strings. The server trims them to 40
  characters (`--max-context`).
- `n`: optional number of candidates, default 1, clamped to 1..8. The beam
  width equals `n` unless the server was started with `--beam`.

Response:
```json
{"id": 1, "candidates": ["解答", "回答", "解凍"], "scores": [-0.14, -2.07, -8.25]}
```
- `candidates` are best first; `scores` are total log-probabilities, in the
  same order. Fewer than `n` candidates may be returned.

Score request: the same fields as a conversion request except `n`, plus
`candidates`, an array of at most 64 strings.
```json
{"id": 2, "op": "score", "kana": "かいとう", "left": "試験問題の", "candidates": ["回答", "解答", "解凍"]}
```
Response, one score per candidate in the request order:
```json
{"id": 2, "scores": [-2.07, -0.14, -8.25]}
```

Errors (either op): `{"id": 1, "error": "message"}`. A line that is not a JSON object gets
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
  worked with Sumibi). It requests `skk-zenz-long-candidates` (default 5).
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
- With `skk-zenz-context-skip-non-japanese` (default t), the text on the
  target's line is always used, and earlier lines are prepended only if they
  contain kana or kanji, looking at most 20 lines up. Code between
  paragraphs (Org source blocks, code around Japanese comments) then gives
  way to the Japanese text above it. Removing code without replacing it
  would not help: code in the context costs little, while a shorter context
  costs more (see `ROADMAP.md`, Phase 6). With nil, the left context is
  simply the characters before the target.
- Right context: up to the same number of characters after
  `skk-henkan-end-point` (or point), stopping at the end of the line, because
  text on following lines is often unrelated.

### Candidate filtering
The client first drops candidates whose score trails the best candidate's by
more than `skk-zenz-max-score-gap` (default 8.0, nil to keep all); in the
evaluation these were broken text, and no intended conversion trailed by
more (`ROADMAP.md`, Phase 5). It then drops candidates that are empty, equal to the reading, already in
`skk-henkan-list`, or duplicated. It also drops candidates that SKK would
misinterpret: `;` starts an annotation, a string that looks like a Lisp form
`(...)` would be evaluated, and newlines or U+FFFD indicate broken output.
Kept candidates get the annotation `;zenz` (`skk-zenz-annotation`, nil for
none).

### Reranking dictionary candidates
Enabled by `skk-zenz-rerank` (default nil). The evaluation behind the defaults
is in `ROADMAP.md` (Phase 6).

- `skk-search` stops at the first program that returns candidates, and
  `skk-search-end-function` runs once per dictionary file. Reordering inside
  either would only see one dictionary, often the personal one with a single
  word. So `(skk-zenz-rerank-search PROGRAMS)` evaluates all PROGRAMS at once,
  merges their candidates in order with `skk-nunion`, and reranks the merged
  list.
- When `skk-zenz-rerank` is non-nil, `skk-zenz-mode` replaces the first run
  of consecutive entries whose function is in `skk-zenz-rerank-programs`
  (dictionary searches) with one `skk-zenz-rerank-search` entry, and expands
  it again when disabled. Entries before the run (such as the kakutei
  dictionary) and after it (such as `skk-search-katakana-maybe`) are kept. If
  the list already calls `skk-zenz-rerank-search`, the mode leaves it alone.
- Readings with at least two candidates are reranked. The first
  `skk-zenz-rerank-limit` (20) candidates are scored with the `score` op,
  with the same context as conversions.
  - Okuri-nashi: the reading is `skk-henkan-key`, which must match
    `skk-zenz-reading-regexp`.
  - Okuri-ari: dictionary candidates are stems. DDSKK's
    `skk-set-okurigana` sets `skk-henkan-key` to the stem reading plus the
    okuri character (かk) and `skk-henkan-okurigana` to the typed okurigana
    (く), and leaves the okurigana in the buffer right after
    `skk-henkan-end-point`. The reading sent is the stem reading plus the
    okurigana (かく), each candidate is scored with the okurigana appended
    (書く, 描く), and the right context starts after the okurigana. The
    joined reading must match `skk-zenz-reading-regexp`. zenz still does not
    generate okuri-ari candidates. Annotations are removed before scoring; Lisp forms are not
  scored and keep their positions.
- `promote` (default): move zenz's best candidate to the front if its score
  beats the first candidate's by more than `skk-zenz-rerank-threshold` (1.0);
  everything else keeps dictionary order, so the positions of later
  candidates stay familiar. `mix`: sort the scored candidates by
  `score - skk-zenz-rerank-weight * log(1 + rank)`.
- The dictionary order carries the user's history: the personal dictionary
  comes first and puts the last confirmed word at its head. The rank term
  (`mix`) and the threshold (`promote`) keep that prior when zenz is unsure,
  which matters most without left context.
- Scoring waits up to `skk-zenz-rerank-timeout` (0.3 s); on failure or
  timeout, candidates are returned in dictionary order.
- Learning is unchanged: reranked words come from dictionaries and are
  learned as usual.

### Learning
- Words confirmed from candidates for long readings (trigger a) are not
  learned. These are usually whole phrases that would clutter the personal
  dictionary, and zenz converts them again next time with fresh context.
- Words confirmed from fallback candidates (trigger b) are learned like
  dictionary words, so the next conversion of the reading finds them in the
  personal dictionary. `skk-zenz-learn-fallback` set to nil excludes them too.
- skk-zenz records the reading, the trigger, and the words it returned for the
  last zenz search (buffer-local). A confirmed word counts as a zenz word if
  the reading matches, the word is one of those, and its annotation is
  `skk-zenz-annotation`. With annotations on, the same word from a dictionary
  has a different (or no) annotation and is treated as a dictionary word. With
  annotations off, any matching word counts as a zenz word.
- Exclusion uses DDSKK's `skk-search-excluding-word-pattern-function` hook. It
  receives the confirmed word with its annotation; returning non-nil keeps the
  word out of the personal dictionary. DDSKK calls it from
  `skk-update-jisyo-p`, while `skk-henkan-key` is still set.
- DDSKK writes the confirmed word to the personal dictionary with its
  annotation. A `:filter-args` advice on `skk-update-jisyo` removes the zenz
  annotation from zenz words first, so learned words do not show it when they
  later come from the dictionary. `skk-zenz-mode` adds and removes the advice.

### Usage log
`skk-zenz-log-file` (default nil) turns on a local log for tuning; nothing is
sent anywhere. `scripts/usage_report.py` summarizes it.

- A `:before` advice on `skk-kakutei` appends one JSON line per confirmation
  in ▼ mode: time, `key`, `okurigana`, the confirmed `word` without
  annotation, its `index` in `skk-henkan-list`, and its `source`
  (`dictionary`, `zenz-long`, `zenz-fallback`, or `registered`).
  `dictionary` covers every non-zenz search program.
- If zenz converted the reading, `zenz` holds the trigger, the request
  status (`ok`, `timeout`, `error`, `unavailable`), the round-trip time in
  ms, the number of candidates dropped by `skk-zenz-max-score-gap`, the
  candidates after filtering, and the confirmed word's rank among them
  (null if absent).
- If reranking scored the candidates, `rerank` holds the status, the time,
  the number of candidates, the first five after reranking, and the
  confirmed word's rank before and after.
- The context is not recorded; readings and words are.
- Data is collected per conversion in a buffer-local variable. A `:before`
  advice on `skk-henkan` clears it when `skk-henkan-list` is empty (a new
  conversion), and a `:filter-return` advice on `skk-henkan-in-minibuff`
  notes a word registered in the minibuffer. `skk-zenz-mode` adds and
  removes the advices; they do nothing while the log is off.
- A failure to write the log is shown in the echo area and does not stop
  the confirmation.

### Process management and failures
- The server starts on the first zenz search and must send a compatible hello
  within `skk-zenz-startup-timeout` (5 s).
- Each search waits up to `skk-zenz-timeout` (1 s). On timeout the search
  returns nil and the late reply is discarded. The server still finishes the
  old request first, so the next search may be delayed.
- If no server or no model is found (see Installation), the search reports it
  with a hint to run `M-x skk-zenz-install`, as a failure. While a download
  runs, searches return nil without a failure.
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

## Release Binaries
Release binaries let users install skk-zenz as a package (elpaca, or
`use-package` with `:vc`) without building zenz-server.

- Version: CMake reads the `;; Version:` header of `skk-zenz.el`, and
  zenz-server reports it in the hello line. A release tag `vX.Y.Z` must match
  the header, so the package version names the server binary to download.
- `cmake -DZENZ_PORTABLE=ON` (used by `make dist`) builds a binary that runs
  on machines other than the build machine:
  - `GGML_NATIVE=OFF`. On x86_64, ggml then enables AVX, AVX2, FMA, F16C, and
    BMI2, which is about x86-64-v3 (Haswell, 2013, and later). Elsewhere it
    uses the base instruction set.
  - `GGML_OPENMP=OFF`, so the binary does not need libgomp. ggml uses its own
    thread pool instead.
  - `-static-libstdc++ -static-libgcc`, so only the C library is needed.
    The glibc requirement is that of the build machine; release builds run
    on Ubuntu 22.04 (glibc 2.35).
- x86-64-v3 runs as fast as `-march=native`; an x86-64-v2 build (SSE4.2 only)
  was about three times slower (findings in `ROADMAP.md`). CPUs without AVX2
  can build from source. Scores differ slightly between builds that use
  different SIMD code (AVX-512 in a native build, for example), which can
  swap low-ranked candidates.
- `make dist` writes `dist/zenz-server-vX.Y.Z-linux-ARCH.tar.gz` (ARCH is
  `amd64` or `arm64`) and a `sha256sum`-style `.sha256` file.
  `scripts/dist.sh` refuses binaries that need libraries other than the C
  library.
- The archive holds `zenz-server`, `LICENSE`, and `THIRD-PARTY-NOTICES`. The
  notices cover the MIT-licensed code compiled into zenz-server: llama.cpp and
  ggml, nlohmann/json (vendored by llama.cpp), llamafile's sgemm, and YaRN
  (cited in ggml-cpu). Review this list when the llama.cpp submodule changes.
- CI (`.github/workflows/`): `test.yml` runs `make test` with the model on
  Ubuntu 24.04 (Emacs 29) for x86_64 and ARM64, and calls `dist.yml`, which
  runs `make dist` on Ubuntu 22.04 for both and converts かいとう with the
  extracted binary. `release.yml` runs `dist.yml` on a `v*` tag and publishes
  the four files as a GitHub release; it fails if the archive names do not
  carry the tag, that is, if the tag does not match the Version header.
- Release procedure: set `;; Version:` in `skk-zenz.el` to `X.Y.Z`, give the
  unreleased section of `CHANGELOG.md` that version, commit, then push the
  tag `vX.Y.Z`.

### Installation (client)
- `skk-zenz-server-program` and `skk-zenz-model-file` default to nil, which
  means: a source checkout's `build/zenz-server` and
  `models/zenz-v3.2-small-Q5_K_M.gguf` (next to the loaded `skk-zenz.el`),
  then the copies in `skk-zenz-install-directory`
  (`~/.emacs.d/skk-zenz/`), then `zenz-server` on `exec-path` and
  `$ZENZ_MODEL`. elpaca loads the package from a build directory of
  symlinks, so it never finds a checkout's build there; package-vc loads it
  from the checkout itself.
- `skk-zenz-version` must equal the Version header (an ERT test checks it).
  The server URL is
  `https://github.com/nekomimist/skk-zenz/releases/download/vX.Y.Z/zenz-server-vX.Y.Z-linux-ARCH.tar.gz`.
  The model URL and SHA-256 are pinned in `skk-zenz.el` and must match the
  Makefile (an ERT test checks it).
- Whether to download, decided once per session from `skk-mode-hook` (the
  user is about to type, and the frame can show a prompt, unlike during init
  or in a daemon without a frame); `skk-zenz-auto-install` chooses between
  asking, downloading, and doing nothing:
  - Server: when none is found, when the downloaded one reports a `version`
    other than `skk-zenz-version` (so a package update fetches the matching
    release), or when the one on `exec-path` speaks another protocol. A server
    set by the user or built in a checkout is never replaced. Checks use
    `zenz-server --version`.
  - Model: when none is found and `ZENZ_MODEL` is unset.
- `M-x skk-zenz-install` always downloads the server and downloads the model
  if none is found.
- Downloads run in the background with curl, so Emacs stays usable while the
  70 MB model arrives. The server archive goes into a temporary directory
  inside the install directory, is checked against its `.sha256`, extracted
  with tar, and its files are renamed into place (a rename replaces a
  running server safely). The model is written to a `.part` file, checked
  against the pinned SHA-256, and renamed. When a download ends, the server
  is stopped and the failure state cleared, so the next search starts the
  new server.
- A user tracking the default branch between releases gets the server of the
  last release. If the protocol changed since then, the mismatch is reported
  and the server must be built from source until the next release.
