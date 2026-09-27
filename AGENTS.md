# Repository Guidelines

## Project Overview
skk-zenz adds neural kana-kanji conversion to DDSKK using the zenz v3.2 model
through llama.cpp. It has two parts:

- `zenz-server`: a C++ program that loads the model once and answers conversion
  requests over stdin/stdout.
- `skk-zenz.el`: an Emacs Lisp client that registers a search function in
  `skk-search-prog-list` and talks to `zenz-server`.

## Where Things Live
- `docs/ARCHITECTURE.md`: design (components, prompt format, protocol, SKK
  integration, llama.cpp dependency).
- `docs/ROADMAP.md`: phases, TODOs, and open questions.
- Keep design notes and task lists in `docs/`, not in this file. This file holds
  only rules for working in the repository.

## Agent Workflow
- Architecture-first: Before changing the protocol, prompt format, decoding,
  trigger policy, or learning exclusion, read `docs/ARCHITECTURE.md`.
- Docs sync: When behavior changes, update affected docs in the same change
  (`README.md`, `docs/ARCHITECTURE.md`, `docs/ROADMAP.md`, and `CHANGELOG.md`
  when user-visible).
- Tests required: Run `make test` after code changes. Add or update ERT tests for
  Emacs Lisp changes and C++ tests for server changes.
- Model-free tests: ERT tests must not require the model or a built server; use a
  fake server script. Tests that need the real model must be opt-in and skip
  cleanly when the model is absent.
- Protocol changes: The client and server share a protocol version. Bump it on
  incompatible changes and make the client report a mismatch clearly.
- No silent breaking changes: For compatibility-impacting changes (protocol,
  configuration variables, default trigger policy), document impact and migration
  steps in user-facing docs.
- Commits: One logical change per commit. Each commit should build and pass
  `make test`.

## Constraints
- Platforms: Linux x86_64 now; Linux ARM64 later. Do not commit build settings
  that only work on x86_64.
- Emacs: Support Emacs 29 and later. Do not use APIs introduced after Emacs 29.
- Never commit model files, llama.cpp build output, or other large binaries.

## Coding Style
- Emacs Lisp: `lexical-binding: t`, `skk-zenz-` prefix for public symbols and
  `skk-zenz--` for internal ones; code must byte-compile without warnings and pass
  `checkdoc`.
- C++: C++17; keep llama.cpp API usage isolated so upstream API changes stay
  local.
