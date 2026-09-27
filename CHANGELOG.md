# Changelog

## Unreleased

### Added
- `zenz-server`: loads zenz v3.2 through llama.cpp and converts readings with
  left and right context. It serves a JSON Lines protocol (version 1) on
  stdin/stdout and also has one-shot `--convert` and `--prompt` modes.
- n-best candidates by beam search with a shared KV cache.
- `skk-zenz.el`: `skk-zenz-mode` adds zenz to `skk-search-prog-list`, first for
  long readings and after the dictionaries for the rest. Words confirmed for
  long readings are not learned; the rest are learned without the zenz
  annotation (`skk-zenz-learn-fallback`).
- `make model` downloads the model and checks its SHA-256.
