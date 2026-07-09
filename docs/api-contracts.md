# API & Data Contracts

**Thesis:** Every interface in this plugin is a promise — to users, to providers, to future maintainers — and promises must be specified precisely enough that violations are detectable by machines, not just by humans.

*Perspectives: Joshua Bloch (API design, fail-fast, hard to misuse) and Leslie Lamport (precise specification, temporal properties, safety invariants). Bloch focuses on the ergonomics of the programmer experience; Lamport focuses on the formal properties that make a system provably correct. We synthesize both: every interface should be easy to use correctly (Bloch) and its invariants should be machine-verifiable (Lamport).*

---

## Principles

### 1. Design interfaces to be hard to misuse

The provider interface has exactly four functions: `validate()`, `preflight()`, `list_models()`, `chat()`. The config is frozen after `resolve()` — you cannot accidentally mutate it. `conversation.get()` returns a deep copy — you cannot accidentally corrupt state. Every API decision should make the wrong thing hard, not just the right thing possible.

**Rationale:** Programmers under pressure will misuse any interface they can misuse. An API that relies on the caller "knowing" not to mutate a returned table is an API with a latent bug. Defensive copying and frozen metatables make misuse impossible rather than merely discouraged.

**Violation:** Returning `state.messages` directly from `conversation.get()`. A caller pushes a message with an invalid role, corrupting the conversation. With deep copy, the caller corrupts their own copy — the canonical state is unaffected.

### 2. Validate at the boundary, trust inside

Every public function validates its inputs. `conversation.append()` validates role and content. `config.validate()` checks types and ranges. `providers/init.lua` validates the provider shape at load time. Once data has crossed the boundary and been validated, internal functions trust it.

**Rationale:** Validation is expensive if done everywhere; it's cheap and essential if done once, at the boundary. Duplicate validation inside internal functions is noise. Missing validation at boundaries is a bug.

**Violation:** Adding `if type(message.role) ~= "string"` checks inside `build_provider_messages()`. The role was already validated by `append()`. If invalid data reaches `build_provider_messages`, the bug is in `append`, not here.

### 3. Error codes are a finite, canonical vocabulary

The error system uses exactly eight codes: `rate_limit`, `server`, `network`, `timeout` (retryable), and `auth`, `invalid_request`, `model_not_found`, `not_implemented` (fatal). Every provider maps its error responses to one of these codes. The stream module makes retry decisions based solely on this vocabulary via `errors.classify()`.

**Rationale:** Open-ended error strings make error handling impossible to reason about. A finite vocabulary means every consumer can handle every case with a complete match. Adding a new error code is a deliberate, documented decision that updates the contract.

**Violation:** A provider returning `{ code = "anthropic_overloaded", message = "..." }`. This code is not in the canonical vocabulary. `errors.classify()` returns "unknown", which is treated as fatal. The correct mapping is `code = "rate_limit"`.

### 4. Specify the callback protocol exactly

The provider streaming contract is: `(on_chunk)* · (on_done | on_error)`. Zero or more chunks, followed by exactly one terminal callback. The stream module enforces this with a cardinality guard — after the first terminal callback, all subsequent callbacks are silenced. Providers must also return a cancel function.

**Rationale:** An unguarded protocol allows double-done, done-after-error, and chunk-after-done bugs. These corrupt the conversation (duplicate assistant messages) or the UI (orphaned spinners). The guard makes these bugs impossible regardless of provider behavior.

**Violation:** A provider that calls `on_done` in the stdout callback AND in the on_exit callback. Without the guard, the assistant message is appended twice. With the guard, the second call is silenced. The guard makes the provider's bug harmless — but the provider should still be fixed.

### 5. The provider interface is four functions, no more

```lua
---@class AiChatProvider
---@field validate fun(config: table): boolean, string?
---@field preflight fun(config?: table, callback?: fun(ok: boolean, err?: string))
---@field list_models fun(config: table, callback: fun(models: string[]))
---@field chat fun(messages: AiChatMessage[], opts: AiChatProviderOpts, callbacks: AiChatCallbacks): CancelFn
```

This interface is validated at load time by `providers/init.lua`. A provider missing any of these four functions fails to load with a clear error. Adding a fifth function to the contract requires updating the validation and all existing providers.

**Rationale:** A minimal interface is easier to implement correctly and easier to verify. Four functions can be held in one head. Forty cannot. Every new provider starts by implementing these four functions — nothing else is required.

**Violation:** Adding `provider.get_context_window()` to the provider interface. Context window data comes from the models registry (`models.lua`) or hardcoded tables in `conversation.lua`. Providers should not be asked for metadata they may not have.

### 6. Config changes have declared temporal semantics

Every mutable config key has a lifecycle category:

| Category | Takes effect… | Examples |
|---|---|---|
| `per_send` | On the next send | `chat.temperature`, `chat.max_tokens`, `chat.thinking` |
| `per_conversation` | On the next new conversation | `chat.system_prompt`, `default_provider`, `default_model` |
| `immediate` | Right now | `chat.auto_scroll`, `ui.show_cost`, `ui.show_tokens` |

These categories are declared in `config.lua`'s `LIFECYCLE` table. When `config.set()` changes a `per_send` setting during an active stream, it notifies the user: "Takes effect on next send."

**Rationale:** A config change that takes effect "eventually" is a source of user confusion and bug reports. Declaring and enforcing temporal semantics makes the behavior predictable and documentable.

**Violation:** Changing `chat.system_prompt` via `config.set()` and expecting the current conversation to use the new prompt. System prompt is `per_conversation` — it takes effect when `conversation.new()` is called.

### 7. Every persisted format is versioned by structure

Conversation JSON files, state.json, and the history index have implicit structure contracts. If the structure changes (a new field, a renamed field), the loading code must handle both old and new formats gracefully — lenient on read, strict on write.

**Rationale:** Users accumulate history files over months. A plugin update that cannot read old history files destroys user data. Lenient reading with validation (skip invalid messages, warn, keep valid ones) preserves data through format evolution.

**Violation:** `conversation.restore()` that crashes on a history file missing the `created_at` field. The actual code defaults to `os.time()` — this is the correct pattern. Read leniently, fill defaults, warn on anomalies.

### 8. Autocmd events are a public API

The `User` autocmd events (`AiChatResponseStart`, `AiChatResponseDone`, `AiChatResponseError`, `AiChatPanelOpened`, etc.) are a contract with users who build statusline integrations and custom workflows. Their names, timing, and payload shape must be treated with the same care as function signatures.

**Rationale:** Users wire these events into their configs. Renaming an event or changing its payload is a breaking change, even if no Lua function signature changed. Autocmd events are the plugin's public bus — additions are safe, removals and renames are breaking.

**Violation:** Renaming `AiChatResponseDone` to `AiChatStreamComplete` in a refactor. Every user with a statusline integration breaks silently.

---

## Violations

### V1: Unvalidated provider load

A provider module that returns a table missing `preflight` or `list_models`. The `providers/init.lua` shape validation catches this at load time — but only if the validation list is kept in sync with the contract. When the contract changes, the validation must change.

### V2: Leaky error codes

A provider inventing its own error codes instead of mapping to the canonical vocabulary. The stream module's `errors.classify()` will return "unknown", which is treated as fatal. The user sees a retry-able error treated as permanent. Map to canonical codes.

### V3: Config mutations without lifecycle awareness

Calling `config.set()` on a key not listed in the `LIFECYCLE` table. The change will take effect at some undefined time. Every mutable config key must be in the lifecycle table with an explicit category.

### V4: Breaking event contracts

Changing the shape of an autocmd event's `data` payload without considering downstream consumers. If `AiChatResponseDone` currently sends `{ response, usage, ttft_ms }`, removing `ttft_ms` breaks any user code that reads it. Additions are safe; removals are breaking.
