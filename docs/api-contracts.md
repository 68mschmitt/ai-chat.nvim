# API & Data Contracts

**Thesis:** A contract that is not enforced is not a contract — it is a suggestion. In a dynamically-typed plugin with four provider implementations and an open-ended user base, moving failure from "sometime later, somewhere else" to "right here, right now" is not optional — it is survival.

---

## Principles

### 1. Specify callback cardinality as a formal contract, not an informal expectation

**Rule:** `provider.chat()` must satisfy the callback sequence `(on_chunk* · (on_done | on_error))` — zero or more chunks followed by exactly one terminal callback. Document this as the contract. Enforce it at the stream layer with a guard that silences callbacks after the first terminal, regardless of provider behavior.

**Rationale:** The `state.active` flag in `stream.lua` and every downstream state transition depends on exactly one terminal callback. If a provider fires `on_done` after `on_error`, the conversation gets a corrupt assistant message. The `errored` flag in each provider exists to enforce this, but it is an implementation patch distributed across four files for a contract that was never stated centrally.

**Violation:** A new provider's HTTP call returns a timeout. The `on_error` callback fires with `code = "network"`. Then the process exits and `on_exit` fires — the author forgot to check the `errored` flag. `on_done` fires with empty content. `stream.lua` appends an empty response to the conversation. The user sees a phantom empty message they cannot delete.

---

### 2. Validate provider shape at load time, not at call time

**Rule:** When `providers/init.lua` loads a provider module via `require`, validate that it exports the four required functions (`validate`, `preflight`, `list_models`, `chat`) and that they are actually functions. Fail loudly at load time. Do not discover a missing function when a user invokes a feature.

**Rationale:** A registry that accepts anything is not a registry — it is a cache. If a provider module is missing `list_models`, you will not know until someone invokes `:AiModels` and gets a nil function call. The error message will point to the caller, not to the broken provider. Five lines of shape validation at registration eliminates this entire class of defect.

**Violation:** A custom provider exports `chat` and `validate` but omits `preflight`. It loads and caches fine. Weeks later, the user starts a new session, `pipeline.lua` calls `preflight` on nil, and the error points to pipeline line 64 — not to the provider that caused the problem.

---

### 3. Normalize response shapes at the adapter boundary — never let optional fields propagate as nil

**Rule:** The `on_done` response must always contain `{ content = string, usage = { input_tokens = number, output_tokens = number }, model = string }`. Optional fields like `thinking` may be nil, but structural fields must have zero values, not absence. Normalize inside each provider's `on_done` handler or in a shared response builder.

**Rationale:** When `usage` is nil, every consumer — pipeline, render, costs, history — must independently nil-check. That is distributed contract enforcement. Normalize once at the boundary. An Ollama response with no usage data becomes `usage = { input_tokens = 0, output_tokens = 0 }` before it leaves the provider.

**Violation:** Ollama returns `{ content = text, model = name }` with no `usage` field. `pipeline.lua` passes this to `costs.record()`, which does `response.usage.input_tokens` and throws "attempt to index nil value." The fix is a one-line nil check in costs — but now you have nil checks in costs, render, history, and anywhere else that reads usage. The normalization belonged in the provider.

---

### 4. Define cancel semantics explicitly — after cancel returns, no further callbacks fire

**Rule:** The cancel function returned by `provider.chat()` guarantees: after it returns, `on_chunk`, `on_done`, and `on_error` will not be called. If the provider cannot guarantee this (because a `vim.schedule` callback is already queued), the stream layer must enforce it with a generation counter or guard flag that silences post-cancel callbacks.

**Rationale:** Without this guarantee, cancelling a stream and immediately starting a new one creates a window where the old stream's `on_chunk` or `on_done` fires into the new stream's render state. The user sees garbled text from two responses interleaved.

**Violation:** User sends a message, then immediately cancels and sends another. The first provider's curl process has not died yet. Its `on_chunk` callback fires with a fragment from the first response, which gets appended to the second response's render buffer. The bug depends on timing and is nearly impossible to reproduce.

---

### 5. Derive registries from registrations, not from hardcoded lists

**Rule:** `providers.list()` should return the set of providers that have been successfully loaded and validated, not a hardcoded array. Adding a provider should require creating one file — not editing the registry, the config validator, and the list function.

**Rationale:** Two lists that must be kept in sync manually — `providers.list()` and `config.validate()`'s valid-provider check — is zero sources of truth. If they diverge, one of them is wrong and the bug is invisible until a user hits the inconsistency.

**Violation:** A contributor adds `providers/google.lua`, updates `config.lua` to accept `"google"`, but forgets the hardcoded array in `providers/init.lua`. Everything works — `providers.get("google")` succeeds via `require` — except provider picker completion omits Google, and any UI using `providers.list()` silently hides it.

---

### 6. Autocmd names and payloads are public API — treat them with the same rigor as function signatures

**Rule:** Document every `User` autocmd name (`AiChatResponseDone`, `AiChatProviderChanged`, etc.) and the exact shape of its `data` payload. Once documented, the name and payload shape are frozen. Adding fields is allowed; removing or renaming fields is a breaking change.

**Rationale:** Users build integrations on autocmds — statusline updates, logging, external tool triggers. If the `data` payload of `AiChatResponseDone` changes shape, those integrations break silently (showing `nil` instead of a value). The autocmd contract is the plugin's extension API; undocumented extension APIs erode trust.

**Violation:** A user builds a statusline that reads `data.usage.output_tokens` from `AiChatResponseDone`. A refactor renames `usage` to `token_usage`. The statusline silently shows nil. The user files a bug. You have no way to know this was a breaking change because the payload was never documented as a contract.

---

### 7. Pure data modules must validate their own invariants on mutation

**Rule:** `conversation.append()` must validate the structural invariant of the message sequence: role must be a legal value, content must be present, and the role must be consistent with the conversation structure (e.g., no two consecutive assistant messages). Reject invalid mutations at the point of insertion, not three function calls later when an API rejects the result.

**Rationale:** A pure data module that accepts anything is not pure — it is permissive. When a retry bug causes `on_done` to fire twice, two consecutive assistant messages enter the conversation. The Anthropic API requires strict alternation and rejects it with a cryptic 400 error. If `append()` had validated the invariant, the bug would surface at the point of corruption with a clear message.

**Violation:** A race condition in the retry path calls `append({ role = "assistant" })` twice. The conversation now has two consecutive assistant messages. `build_provider_messages` sends it. The API returns 400. The user sees "invalid request" with no indication that the real problem is a corrupted conversation history.

---

### 8. Partition configuration into lifecycle categories and document which settings belong to which

**Rule:** Configuration settings fall into three categories: (a) *per-send* — takes effect on next `pipeline.send()`, safe to change anytime (model, temperature, thinking); (b) *per-conversation* — takes effect on next new conversation only (system prompt, provider); (c) *immediate* — takes effect now (UI settings, keymaps). `config.set()` should respect these categories — warn or no-op if a per-conversation setting is changed mid-conversation.

**Rationale:** `config.set("chat.thinking", true)` mid-stream produces undefined behavior: the current stream was started without thinking mode, but subsequent reads of config see it enabled. Without lifecycle categories, runtime mutation is a source of inconsistency that no amount of testing can prevent.

**Violation:** User enables thinking mode while a response is streaming. The current stream is unaffected — it was already started. They send another message. Pipeline reads config, sees thinking enabled, omits temperature. But the conversation history contains messages generated without thinking. Depending on the provider, this works, produces confusion, or errors.

---

## Anti-Patterns

### The Unvalidated Registry
A provider registry that accepts any module via `require` without checking its shape. Missing functions surface as nil-call errors at the point of use, with error messages pointing to the caller instead of the broken provider.

### The Distributed Nil Check
An optional field in a response shape that forces every consumer to independently check for nil. Each consumer is a new opportunity to forget the check. Normalize at the boundary; distribute the normalized value.

### The Undocumented Extension Point
An autocmd or callback that users depend on but whose payload shape is never specified. Any change to the payload is a breaking change that cannot be detected by tests because the contract was never written down.

### The Silent Contract Violation
A `conversation.append()` that accepts any table without validating role, content, or sequence. Invalid data enters the system and propagates until it hits an external API that rejects it — three modules and two async boundaries away from the cause.

### The Timing-Dependent Cancel
A cancel function that kills the process but does not prevent already-queued callbacks from firing. The system is correct only if the timing cooperates. Under load or slow scheduling, stale callbacks corrupt the new stream's state.

---

## Reference: Provider Interface

Every provider module must export:

```lua
M.validate(config)          → boolean, string?
M.preflight(config, cb)     → nil  (calls cb(ok, err?))
M.list_models(config, cb)   → nil  (calls cb(string[]))
M.chat(messages, opts, callbacks) → cancel_fn
  -- callbacks: { on_chunk(text), on_done(response), on_error(err) }
  -- response:  { content, thinking?, usage?, model? }
  -- err:       { code, message, retryable? }
```

Error codes must come from the canonical set in `errors.lua`:
`rate_limit`, `server`, `network`, `timeout` → retryable
`auth`, `invalid_request`, `model_not_found`, `not_implemented` → fatal

Bedrock uses `AWS_BEARER_TOKEN_BEDROCK`; Anthropic uses `ANTHROPIC_API_KEY`. Neither uses the AWS CLI — the Bedrock provider does direct HTTP with a bearer token.
