# AGENTS.md — ai-chat.nvim

A Neovim plugin providing AI chat via a side-panel buffer. Supports Anthropic, Amazon Bedrock, Ollama, and any OpenAI-compatible endpoint. Written entirely in Lua; requires Neovim ≥ 0.10.

---

## Design Principles

Before making architectural decisions or non-trivial changes, read the project philosophy documents in `docs/`. These are the durable constraints that survive every refactor.

| Document | Thesis | Read when... |
|---|---|---|
| `docs/architecture.md` | Keep things separate that are separate. | Adding modules, changing data flow, touching boundaries. |
| `docs/code-conventions.md` | Every convention serves the reader six months from now. | Writing new code, reviewing patterns, error handling. |
| `docs/testing.md` | A test earns its place by enabling change, not punishing it. | Adding tests, deciding what to test, mocking decisions. |
| `docs/api-contracts.md` | A contract not enforced is a suggestion. | Changing interfaces, adding providers, modifying callbacks. |
| `docs/performance.md` | Never block the editor; measure before optimizing. | Performance work, adding per-chunk logic, caching decisions. |
| `docs/events.md` | Plugin lifecycle events are a public API. | Adding autocmds, hooking into events, extending integrations. |

---

## Commands

```bash
make test                              # Run all tests (headless nvim)
make test-file FILE=tests/foo_spec.lua # Run a single spec file
make verify                            # Run v0.1 verification suite
make lint                              # stylua --check (CI gate)
make format                            # stylua auto-format
make clean                             # Remove .deps/
```

Tests run inside headless Neovim — there is no standalone Lua test runner. `make test` is the only way to run them; `lua tests/foo_spec.lua` will not work.

---

## Formatting

StyLua with 120-column width, 4-space indent, `AutoPreferDouble` quotes, `Always` call parentheses. CI fails if `stylua --check` finds diffs. Run `make format` before committing.
