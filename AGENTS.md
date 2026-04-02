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

**Key invariants (summary):**
- Pure data modules (`conversation.lua`, `errors.lua`) never `require` UI or providers — everything through arguments.
- Dependencies flow inward: edge → orchestration → data. Never the reverse.
- Every piece of mutable state has exactly one owning module. Others get snapshots or callbacks.
- The provider boundary is a protocol: nothing provider-specific leaks above `providers/`.
- All editor side effects are quarantined behind `vim.schedule()` in `ui/` only.
- Mock only at `vim.system`. Test through public APIs. Guard async assertions with timeouts.
- Never block the main loop. Accept deep copies for correctness. Measure end-to-end before optimizing internals.

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

## Architecture

```
plugin/ai-chat.lua          ← entry point: registers :Ai* commands, nothing else
lua/ai-chat/
  init.lua                  ← public API + module coordinator (owns UI state refs)
  pipeline.lua              ← send orchestration (extracted from init.lua)
  conversation.lua          ← pure data: message history, context truncation
  stream.lua                ← streaming lifecycle: start / cancel / retry
  errors.lua                ← error classification (retryable vs fatal)
  config.lua                ← defaults, resolve(), validate(), get()
  state.lua                 ← persists last-used provider/model across sessions
  models.lua                ← model registry with pricing/context-window metadata
  providers/
    init.lua                ← registry: get(), exists(), preflight(), list()
    anthropic.lua
    bedrock.lua
    ollama.lua
    openai_compat.lua
  ui/
    init.lua                ← opens/closes the two-buffer split
    chat.lua                ← chat buffer + winbar
    input.lua               ← input buffer
    render.lua              ← writes messages into the chat buffer via nvim API
    thinking.lua            ← detects/folds <thinking> blocks
    spinner.lua
  history/
    init.lua                ← save/load/browse public interface
    store.lua               ← one JSON file per conversation under stdpath("data")
  util/
    costs.lua / tokens.lua / log.lua / ui.lua
```

**Data flow for a send:**
`M.send()` → `pipeline.send()` → `conversation.build_provider_messages()` → `stream.send(provider, ...)` → `provider.chat()` (SSE via `vim.system curl`) → `on_chunk` → `render.append()` → `on_done` → `conversation.append()` + history save + cost record.

---

## Formatting

StyLua with 120-column width, 4-space indent, `AutoPreferDouble` quotes, `Always` call parentheses. CI fails if `stylua --check` finds diffs. Run `make format` before committing.

---

## Gotchas

- **Thinking mode + temperature**: Anthropic rejects requests that set `temperature` when `thinking` is enabled. `pipeline.lua` omits temperature when `opts.thinking` is true — replicate this in any new provider that supports thinking.
- **Bedrock stream format**: The response stream is not plain SSE. Each event frame contains a Base64-encoded Anthropic JSON payload inside an `event{...}` envelope. See `providers/bedrock.lua` for the two-layer decode.
- **Anthropic system prompt**: The Anthropic API requires the system prompt as a top-level `system` field, not as a `messages[0]` entry with `role="system"`. The provider strips it from the messages array before sending.
- **`vim.uv` vs `vim.loop`**: The codebase uses `vim.uv or vim.loop` for compatibility with Neovim 0.9 shims, even though 0.10 is required. Match this pattern for any new libuv usage.
- **Buffer modifiable flag**: The chat buffer is set `modifiable = false` after every write. `render.lua` sets it `true` before writing and `false` after. Forgetting this causes silent write failures.
- **`vim.system` temp file pattern**: Providers write the JSON request body to a temp file and pass `@<tmpfile>` to curl. The temp file is deleted in both the success and error branches. Match this pattern for new providers.
- **Preflight is once-per-session-per-provider**: `pipeline.lua` tracks `pstate.preflight_done[provider_name]` and only calls preflight on the first send. Preflight should be a lightweight check, not a blocking call.
- **`conversation.get()` returns a deep copy**: Callers always receive a snapshot. Mutating the return value does nothing — use `conversation.append()`, `conversation.set_model()`, etc.
- **History auto-saves on every `on_done`**: There is no explicit "dirty" tracking. Every completed response triggers `history.save()` when history is enabled.
