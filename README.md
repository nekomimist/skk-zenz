# skk-zenz

skk-zenz adds neural kana-kanji conversion to [DDSKK](https://github.com/skk-dev/ddskk)
using the [zenz v3.2](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf)
language model. The model runs locally on the CPU through
[llama.cpp](https://github.com/azooKey/llama.cpp), so no text leaves your
machine and there is no API cost.

- Long readings (10 characters or more by default) are converted by zenz
  before any dictionary.
- Other readings get zenz candidates after the dictionary candidates run out,
  before dictionary registration.
- zenz uses the text around the conversion target as context, so the same
  reading converts differently depending on the sentence
  (試験問題の**解答** vs. 電子レンジで**解凍**).
- Words confirmed from zenz candidates for long readings are not added to
  your personal dictionary. Words confirmed from the other zenz candidates are
  learned like dictionary words.

Status: experimental. Tested on Linux x86_64 with Emacs 29.4 and 31.1.

## Requirements

- Linux x86_64 (ARM64 is planned)
- CMake 3.16 or later and a C++17 compiler
- Emacs 29.1 or later with DDSKK
- git and curl
- About 100 MB of memory for the server

## Build

```sh
git clone --recurse-submodules --shallow-submodules <repository-url> skk-zenz
cd skk-zenz
make build   # builds build/zenz-server
make model   # downloads the model (70 MB) to models/ and checks its SHA-256
```

If you cloned without `--recurse-submodules`, run
`git submodule update --init --depth 1` first.

Check the server from the command line:

```sh
$ build/zenz-server --model models/zenz-v3.2-small-Q5_K_M.gguf \
    --convert かいとう --left 試験問題の -n 3
解答
回答
解凍
```

## Emacs setup

```elisp
(add-to-list 'load-path "/path/to/skk-zenz")
(require 'skk-zenz)
(skk-zenz-mode 1)
```

Enable `skk-zenz-mode` after your `skk-search-prog-list` is set up: the mode
adds `(skk-zenz-search :long)` to the head of the list and
`(skk-zenz-search :fallback)` to the tail. Disabling the mode removes both and
stops the server.

When skk-zenz is loaded from this directory, it finds `build/zenz-server` and
`models/zenz-v3.2-small-Q5_K_M.gguf` automatically. Otherwise set
`skk-zenz-server-program` and `skk-zenz-model-file` (or the `ZENZ_MODEL`
environment variable).

### Options

| Variable | Default | Meaning |
|---|---|---|
| `skk-zenz-min-length` | `10` | Readings at least this long go to zenz first. `nil` means zenz is only a fallback. |
| `skk-zenz-long-candidates` | `3` | Candidates requested for long readings. |
| `skk-zenz-fallback-candidates` | `5` | Candidates requested after the dictionaries. |
| `skk-zenz-context-length` | `40` | Characters of context sent on each side. `0` disables context. |
| `skk-zenz-annotation` | `"zenz"` | Annotation on zenz candidates. `nil` for none. |
| `skk-zenz-learn-fallback` | `t` | Learn words confirmed from candidates shown after the dictionaries. |
| `skk-zenz-timeout` | `1.0` | Seconds to wait for a conversion. |
| `skk-zenz-server-args` | `nil` | Extra server arguments, for example `("--threads" "8")`. |
| `skk-zenz-reading-regexp` | hiragana, ー, 、。・！？ | Readings that are sent to zenz. |

Conversion takes about 20 ms for short readings and 60–130 ms for a 20-character
reading on a recent x86_64 CPU with 4 threads; more candidates take longer.

### Troubleshooting

- Server problems are shown in the echo area. After a failure, skk-zenz waits
  `skk-zenz-retry-interval` (30 s) before starting the server again;
  `M-x skk-zenz-restart` retries immediately.
- The server's stderr is in the buffer ` *zenz-server stderr*`.
- Set `skk-zenz-debug` to `t` to log the protocol traffic to `*Messages*`.

## Development

```sh
make test
```

`make test` builds the server, runs the C++ tests, byte-compiles
`skk-zenz.el`, and runs the ERT tests. On the first run it clones DDSKK into
`build/deps/ddskk`; set `DDSKK_DIR` to use an installed copy instead. Tests
that need the model run when `models/zenz-v3.2-small-Q5_K_M.gguf` (or
`ZENZ_MODEL`) exists and are skipped otherwise.

`scripts/bench_server.py` measures server latency. Design notes are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and plans in
[docs/ROADMAP.md](docs/ROADMAP.md).

## License

MIT License. See [LICENSE](LICENSE).

## Third-party components

- llama.cpp ([azooKey fork](https://github.com/azooKey/llama.cpp), branch
  `azookey/b9637-compat`): MIT License. The fork is required because upstream
  llama.cpp cannot load the zenz tokenizer.
- zenz-v3.2-small model by Miwa-Keita: Apache License 2.0. Not included in
  this repository; `make model` downloads it.
- The prompt format and its preprocessing follow
  [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)
  (MIT License, Copyright (c) 2023 Miwa / Ensan).
