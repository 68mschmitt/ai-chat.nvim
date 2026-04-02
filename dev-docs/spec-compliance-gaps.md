# Spec Compliance Gaps

Systematic audit of the codebase against the five specification documents in `docs/`. Each gap is a concrete instance where the implementation diverges from a stated principle. Organized by severity, with file locations and spec references for traceability.

**Audit date:** 2026-04-02
**Spec documents audited:** `docs/architecture.md`, `docs/code-conventions.md`, `docs/testing.md`, `docs/api-contracts.md`, `docs/performance.md`

---

## How to Use This Document

- **Before starting work on a gap**, read the referenced spec section for full context on *why* the rule exists.
- **When a gap is resolved**, move it to the Resolved section at the bottom with a date and PR/commit reference.
- **When new gaps are found**, add them to the appropriate severity tier with the same format.

---

## Critical — Structural violations the specs explicitly warn against

### GAP-01: `conversation.append()` performs zero validation

**Spec:** api-contracts.md §7 — *"Reject invalid mutations at the point of insertion, not three function calls later when an API rejects the result."*

**Location:** `lua/ai-chat/conversation.lua:92–94`

**Finding:** `append()` is a bare `table.insert(state.messages, message)`. No validation of:
- Role legality (any string, nil, or absent accepted)
- Content presence (nil or absent accepted)
- Message sequence (two consecutive assistant messages accepted silently)
- Type (non-table values accepted by `table.insert`)

**Impact:** A retry bug that fires `on_done` twice produces two consecutive assistant messages. The Anthropic API requires strict alternation and rejects it with a 400 — three modules and two async boundaries away from the corruption point.

**Fix direction:** Validate role ∈ `{"user", "assistant", "system"}`, require non-nil content, reject consecutive same-role messages (with an explicit override for system). Reject at the mutation point with a clear error.

---

### GAP-02: No callback cardinality enforcement at the stream layer

**Spec:** api-contracts.md §1 — *"Enforce `(on_chunk* · (on_done | on_error))` at the stream layer with a guard that silences callbacks after the first terminal."*

**Location:** `lua/ai-chat/stream.lua:85–154`

**Finding:** `stream.lua` has no generation counter, no `terminal_fired` flag, and no wrapper that intercepts callbacks after the first terminal. The only enforcement is the `errored` flag distributed across four separate provider files. Additionally, already-queued `vim.schedule` `on_chunk` callbacks can fire after `on_error`.

**Impact:** A new provider that omits the `errored` check silently violates the contract. The stream layer cannot detect or prevent double-terminal callbacks.

**Fix direction:** Wrap the provider's callbacks at the `_do_send` call site:
```lua
local terminal_fired = false
local guarded = {
    on_chunk = function(text)
        if terminal_fired then return end
        callbacks.on_chunk(text)
    end,
    on_done = function(response)
        if terminal_fired then return end
        terminal_fired = true
        callbacks.on_done(response)
    end,
    on_error = function(err)
        if terminal_fired then return end
        terminal_fired = true
        callbacks.on_error(err)
    end,
}
```
Pass `guarded` to the provider instead of raw callbacks.

---

### GAP-03: Cancel cannot silence already-queued `vim.schedule` callbacks

**Spec:** api-contracts.md §4 — *"After cancel returns, `on_chunk`, `on_done`, and `on_error` will not be called."*

**Location:**
- `lua/ai-chat/stream.lua:33–48` — `M.cancel()`
- `lua/ai-chat/providers/anthropic.lua:309–314` — cancel function (representative of all four)

**Finding:** All four providers' cancel functions send `SIGTERM` but set no silencing flag. `stream.cancel()` sets `state.active = false` but the `on_chunk` closures don't check it. Between cancel and process death, queued `vim.schedule` callbacks fire into stale state.

**Impact:** Cancel during streaming → immediately start new stream → stale `on_chunk` from old stream fires. Partially mitigated by `stream_render` being created per-send, but the window exists.

**Fix direction:** Combine with GAP-02's guard. A generation counter incremented on each `_do_send` and checked in every guarded callback would silence both post-cancel and post-terminal callbacks in one mechanism.

---

### GAP-04: Streaming state is scattered boolean flags, not a state machine

**Spec:** architecture.md §7 — *"Encode the state as a single named value, not as predicates over scattered booleans."*

**Location:** `lua/ai-chat/stream.lua:15–20`

**Finding:** State is `{ active = false, cancel_fn = nil, retry_count = 0, retry_timer = nil }` — four independent fields. The actual state (idle, streaming, retrying, cancelling) must be inferred from combinations. No single `phase` enum. No assertion that the current state is a legal precondition for any operation.

**Impact:** 16 possible flag combinations, ~5 meaningful. The remaining 11 are unguarded. Transient invalid states (e.g., `active=true, cancel_fn=nil, retry_timer=nil`) exist between error handling and retry setup.

**Fix direction:** Replace with:
```lua
local state = {
    phase = "idle", -- "idle" | "streaming" | "retrying" | "cancelling"
    cancel_fn = nil,
    retry_count = 0,
    retry_timer = nil,
}
```
Assert legal preconditions at the top of each function (e.g., `send` requires `phase == "idle"`, `cancel` requires `phase ∈ {"streaming", "retrying"}`).

---

### GAP-05: `store.list()` reads every conversation file synchronously on every save

**Spec:** performance.md §1 — this is the *exact example* given as a violation.

**Location:** `lua/ai-chat/history/store.lua:57–85` (list), `store.lua:97–98` (_prune calls list)

**Finding:** `list()` calls `vim.fn.readfile` + `vim.json.decode` in a loop over every `.json` file. `_prune()` calls `list()` and is called by `write()` on every save. Since `pipeline.on_done` calls `history.save()`, **every completed response triggers a full synchronous scan of all history files**.

**Impact:** With N conversations, every response completion blocks the main loop for O(N) synchronous file reads + JSON decodes. The spec estimates 200 × 50KB = 10MB of synchronous I/O.

**Fix direction:** Maintain a lightweight index file (`index.json`) with `{ id, title, timestamp, provider, model }` per entry. Append on save. `list()` reads only the index. Rebuild the index on corruption or upgrade.

---

### GAP-06: Provider shape is never validated at load time

**Spec:** api-contracts.md §2 — *"Validate at load time. Fail loudly. Do not discover a missing function when a user invokes a feature."*

**Location:** `lua/ai-chat/providers/init.lua:13–25`

**Finding:** `M.get()` does `pcall(require, ...)` and caches unconditionally. No check for `validate`, `preflight`, `list_models`, or `chat`. `M.validate()` and `M.preflight()` nil-check at call time and silently succeed if the function is absent.

**Impact:** A provider missing `preflight` loads fine. `pipeline.lua` calls preflight → registry returns `callback(true)` → no error, no warning. A provider missing `list_models` fails only when `:AiModels` is invoked.

**Fix direction:** After `require`, validate shape:
```lua
local required = { "validate", "preflight", "list_models", "chat" }
for _, fn_name in ipairs(required) do
    if type(provider[fn_name]) ~= "function" then
        error(("[ai-chat] Provider '%s' missing required function '%s'"):format(name, fn_name))
    end
end
```

---

### GAP-07: No provider contract test suite

**Spec:** testing.md §5 — *"One parameterized test suite that runs against each provider."*

**Location:** `tests/` — absence

**Finding:** Only Ollama has streaming tests (`mock_http_spec.lua`). Anthropic, Bedrock, and OpenAI-compat have **zero** `chat()` tests. The Bedrock two-layer Base64 decoder and Anthropic system-prompt placement are completely untested.

**Impact:** Contract divergence across providers is invisible. Error codes tested for one provider but not others. The translation layer — where bugs actually live — is untested for 3 of 4 providers.

**Fix direction:** Create `tests/providers/contract_spec.lua` with one parameterized suite. For each provider, mock `vim.system` with provider-appropriate responses and assert:
1. `validate(valid_config)` returns `true`
2. Auth failure response → `on_error` with `code = "auth"`
3. Streamed response → `on_chunk` fires N times, `on_done` receives assembled content + usage
4. Network failure → `on_error` with `code = "network"` and `retryable = true`
5. The request body sent to curl has the correct structure (system prompt placement, temperature handling, etc.)

---

## Significant — Violations that undermine stated principles

### GAP-08: `render.lua` contains business logic that belongs in orchestration

**Spec:** architecture.md §2, §5

**Location:** `lua/ai-chat/ui/render.lua:223–229`

**Finding:** The `finish()` closure in `begin_response` does config reads, model registry lookups, and cost estimation. The same pricing lookup also appears in `pipeline.lua:137–139`. A UI leaf module is doing orchestration-layer work.

**Fix direction:** Compute cost in `pipeline.on_done` and pass it to `render.finish()` as a pre-computed value. Remove config/models/costs requires from render.lua.

---

### GAP-09: `config.get()` returns mutable references

**Spec:** architecture.md §3 — *"Never hand out mutable references to owned state."*

**Location:** `lua/ai-chat/config.lua:184–186`

**Finding:** Returns the raw `resolved` table. Any caller that does `config.get().chat.thinking = true` silently mutates global config. `conversation.get()` correctly deepcopies; `config.get()` does not. `init.lua:167` passes the raw reference into `pipeline.send()`.

**Fix direction:** Either `return vim.deepcopy(resolved)` (the spec accepts this cost for config — see performance.md accepted tradeoffs table) or return a frozen/read-only proxy. The performance.md tradeoff table explicitly *rejects* deep copying config on every access — so the alternative is a read-only wrapper or ensuring all mutation goes through `config.set()`.

---

### GAP-10: Two independent hardcoded provider lists

**Spec:** api-contracts.md §5 — *"Derive registries from registrations, not from hardcoded lists."*

**Locations:**
- `lua/ai-chat/providers/init.lua:42–44` — `M.list()` returns `{ "ollama", "anthropic", "bedrock", "openai_compat" }`
- `lua/ai-chat/config.lua:228–238` — `valid_providers` array in `validate()`

**Finding:** Two lists that must be kept in sync manually. Adding a provider requires updating both. Neither is derived from loaded modules.

**Fix direction:** `providers.list()` returns the keys of the loaded-providers cache. `config.validate()` calls `providers.list()` or `providers.exists()` instead of maintaining its own list.

---

### GAP-11: Context windows live in two independent places

**Spec:** performance.md §5 — *"One authoritative source with a fallback chain."*

**Locations:**
- `lua/ai-chat/conversation.lua:34–55` — 15 hardcoded model entries
- `lua/ai-chat/models.lua:234–240` — `M.get_context_window()` from registry

**Finding:** `conversation._get_context_window()` uses only its own hardcoded tables and user config — it never consults `models.lua`. `models.lua:get_context_window()` is dead code from conversation's perspective.

**Fix direction:** `conversation._get_context_window()` should call `models.get_context_window()` as primary source, falling back to its hardcoded table only if the registry returns nil. Or: move the hardcoded table into `models.lua` as the fallback and have a single lookup path.

---

### GAP-12: Buffer modifiable toggle is not pcall-protected

**Spec:** code-conventions.md §5 — *"Wrap buffer writes in a helper that guarantees restoration via pcall."*

**Location:** `lua/ai-chat/ui/render.lua:29–79` (render_message), `render.lua:95–98` (clear)

**Finding:** Both functions set `modifiable = true`, perform buffer writes, then set `modifiable = false` — with no pcall. If the buffer is deleted between validity check and write, the flag is never reset.

**Fix direction:** Extract a helper:
```lua
local function with_modifiable(bufnr, fn)
    vim.bo[bufnr].modifiable = true
    local ok, err = pcall(fn)
    vim.bo[bufnr].modifiable = false
    if not ok then error(err) end
end
```

---

### GAP-13: Tests call underscore-prefixed internal functions

**Spec:** testing.md §3 — *"Never call underscore-prefixed internal functions in tests."*

**Locations:**
- `tests/conversation_spec.lua:105–130` — `_truncate_to_budget` (3 calls) — the spec's **exact named example**
- `tests/pipeline_spec.lua:93–140` — `_get_context_window` (5 calls)
- `tests/state_spec.lua:10,15,56,95` — `_reset` (4 calls, test harness use)

**Fix direction:** Test truncation through `build_provider_messages` by passing message lists that exceed the budget and asserting the result fits. Test context window selection through `build_provider_messages` output length. Replace `_reset` with re-initialization or module reload.

---

### GAP-14: Lazy requires without cycle-breaking justification

**Spec:** code-conventions.md §6 — *"Only for breaking cycles. Document why with a comment."*

**Locations:**
- `lua/ai-chat/init.lua:28–52` — lazy refs to conversation, stream, pipeline
- `lua/ai-chat/stream.lua:77–78` — require inside `_do_send`
- `lua/ai-chat/ui/render.lua:183,223–227,260` — require inside closures
- `lua/ai-chat/ui/thinking.lua:88,123` — require inside functions
- `lua/ai-chat/ui/chat.lua:98,109,121,134,137+` — require inside functions throughout
- `lua/ai-chat/conversation.lua:192` — require inside `_truncate_to_budget`

**Finding:** None of these have comments documenting a circular dependency, and investigation confirms no cycles exist for most of them.

**Fix direction:** Move all non-cycle-breaking requires to file top. For any that genuinely break a cycle, add a comment explaining which cycle.

---

### GAP-15: Autocmd events are undocumented

**Spec:** api-contracts.md §6 — *"Document every User autocmd name and the exact shape of its data payload. Once documented, the name and payload shape are frozen."*

**Events fired (undocumented):**

| Event | Location | Payload |
|---|---|---|
| `AiChatPanelOpened` | `init.lua:131` | `{ winid, bufnr }` |
| `AiChatPanelClosed` | `init.lua:152`, `lifecycle.lua:22` | *(none)* |
| `AiChatConversationCleared` | `init.lua:219` | *(none)* |
| `AiChatProviderChanged` | `init.lua:310` | `{ provider, model }` |
| `AiChatResponseStart` | `pipeline.lua:106` | `{ provider, model }` |
| `AiChatResponseDone` | `pipeline.lua:144` | `{ response, usage }` |
| `AiChatResponseError` | `pipeline.lua:151` | `{ error }` |

**Fix direction:** Add an `Autocmds` section to the README or a dedicated `docs/events.md`. Freeze names and payload shapes. Note: `AiChatResponseDone` sends both `response` and `usage` as top-level keys — `usage` is redundant with `response.usage` and should be documented or removed.

---

## Moderate — Real but lower-severity deviations

### GAP-16: Three files exceed 300 lines

**Spec:** code-conventions.md §4 — *"If a file grows past 300 lines, it is probably doing two things."*

| File | Lines | Concern |
|---|---|---|
| `init.lua` | 474 | Model picker, provider picker, history browser, key display, config display — several extractable |
| `bedrock.lua` | 439 | HTTP transport + Anthropic event protocol decoder could split |
| `render.lua` | 418 | Message rendering + code block navigation + markup styling |

---

### GAP-17: pcall wrapping internal `config.get()` calls

**Spec:** code-conventions.md §7 — *"Do not pcall your own internal functions."*

**Locations:** `thinking.lua:87`, `render.lua:182`, `chat.lua:97`

**Finding:** `config.get()` cannot throw — wrapping it in pcall swallows future bugs and silently falls back to defaults.

---

### GAP-18: Scattered mutable locals outside state tables

**Spec:** code-conventions.md §1 — *"Mutable state lives in a single `local state = {}` at the top."*

**Locations:**
- `ui/spinner.lua:8–11` — `timer`, `frame_index`, `saved_winbar`, `active_winid`
- `util/log.lua:6–7` — `log_config`, `log_file`
- `history/store.lua:7–8` — `storage_path`, `max_conversations`
- `models.lua:23–27` — `_cache`, `_last_fetch`

---

### GAP-19: Vague error messages from providers

**Spec:** code-conventions.md §8 — *"Include the specific failure and a concrete next step."*

**Locations:**
- `bedrock.lua:313–316` — auth errors pass raw "Forbidden" with no next step
- `anthropic.lua:282` — passes raw API string, no "check ANTHROPIC_API_KEY" guidance
- `openai_compat.lua:250` — same pattern

**Positive example:** `ollama.lua:156–159` — *"Is Ollama running at {host}? Start it with `ollama serve`."* All providers should follow this model.

---

### GAP-20: Provider-specific logic outside `providers/`

**Spec:** architecture.md §4

**Location:** `lua/ai-chat/util/costs.lua:37` — `if provider == "ollama" then return 0 end`

Also: `health.lua` has extensive provider-name branching (lines 52–111), arguably acceptable for diagnostics but ideally each provider would expose a `health_check()` function.

---

### GAP-21: No TTFT measurement instrumentation

**Spec:** performance.md §2 — *"Measure with a timestamp at the top of `pipeline.send()` and another in the first `on_chunk`."*

**Location:** absence in `pipeline.lua` and `stream.lua`

**Finding:** `pipeline.lua:100` records `os.time()` (second resolution) for the request timestamp but captures no first-chunk time. No `vim.uv.hrtime()` instrumentation exists anywhere in the streaming path.

---

### GAP-22: `config.set()` has no lifecycle categories

**Spec:** api-contracts.md §8

**Location:** `lua/ai-chat/config.lua:192–205`

**Finding:** `set()` is a raw path-value setter. No distinction between per-send, per-conversation, and immediate settings. No warning when changing `chat.thinking` while a stream is active (`init.lua:328`).

---

### GAP-23: Config deep-copied on every streaming chunk

**Spec:** performance.md §4 — *"Avoid adding O(n) operations that run on every chunk."*

**Location:** `lua/ai-chat/ui/render.lua:182–184`

**Finding:** `require("ai-chat.config").get()` is called inside the `append` closure (per-chunk auto-scroll check). If `config.get()` does a deepcopy (as GAP-09 recommends), this becomes 200 deep copies per response. The config doesn't change during streaming — capture it once in `begin_response`.

---

### GAP-24: `handle_*` / `process_*` naming in bedrock

**Spec:** code-conventions.md §2 — *"Name functions for what they return or do, never for when they are called."*

**Location:** `lua/ai-chat/providers/bedrock.lua:345,385`

**Finding:** `_process_stream_buffer` and `_handle_anthropic_event` — named for trigger, not effect. Better: `decode_bedrock_frames`, `dispatch_event`.

---

## Resolved

*Move gaps here when fixed, with date and PR/commit reference.*

| Gap | Resolved | Reference |
|---|---|---|
| — | — | — |
