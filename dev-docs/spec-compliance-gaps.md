# Spec Compliance Gaps

Systematic audit of the ai-chat.nvim codebase against all principles stated in the `docs/` specification files. Every finding is evidence-based with exact file paths and line numbers.

**Audit date:** 2026-04-02
**Spec documents audited:** architecture.md, code-conventions.md, testing.md, api-contracts.md, performance.md, events.md

---

## How to Use This Document

- Each gap has a stable ID (GAP-01, GAP-02, ...) that can be referenced in commits and PRs.
- When a gap is resolved, move its entry to the **Resolved** table at the bottom with a date and PR/commit reference.
- When new gaps are discovered, append them with the next sequential ID — never reuse IDs.
- The **What's Clean** section documents areas of full compliance; update it as gaps are resolved.

---

## Critical — Structural violations the specs explicitly warn against

These are cases where a spec describes a violation example and that exact pattern exists in the code.

### GAP-01: config.lua reaches into orchestration module (stream.lua)
**Spec:** architecture.md §1 — "A module designated as 'pure data' never calls `require` on UI, provider, or editor modules."
**Location:** `config.lua:266`
**Finding:** `config.set()` lazily requires `ai-chat.stream` to check `stream.is_active()`. This is a data → orchestration dependency — the exact reversed dependency flow the architecture doc prohibits.
**Impact:** config.lua cannot be tested in isolation; loading config pulls in the entire streaming stack.
**Fix direction:** Remove the streaming check from `config.set()`. The caller (`init.lua`) should check `stream.is_active()` before calling `config.set()`, or pass an `is_streaming_fn` callback.

### GAP-02: config.lua reaches into edge module (providers)
**Spec:** architecture.md §1 — "A module designated as 'pure data' never calls `require` on UI, provider, or editor modules."
**Location:** `config.lua:314`
**Finding:** `config.validate()` lazily requires `ai-chat.providers` to check `providers.exists()`. This is a data → edge dependency.
**Impact:** Validating config requires the provider registry to be loadable, creating a circular initialization concern.
**Fix direction:** Accept a `known_providers` list or `provider_exists_fn` callback as an argument to `validate()`. The caller already has access to the providers module.

### GAP-03: Bidirectional dependency cycle between ui/ and init.lua
**Spec:** architecture.md anti-pattern "The Bidirectional Dependency" — "Two modules that require each other, directly or through callbacks they were not explicitly given."
**Location:** `ui/chat.lua:138,141`, `ui/input.lua:131,153,171`
**Finding:** `init.lua` requires `ui/chat.lua` and `ui/input.lua`. Those modules lazily require `ai-chat` (init.lua) back inside keymap callbacks. Comments acknowledge this: "Lazy: breaks init → ui → chat → init cycle." The cycle exists and is managed by lazy require, but the architecture doc names this as the most dangerous anti-pattern.
**Impact:** The dependency cycle prevents clean layering and makes it impossible to use ui/ modules independently of the coordinator.
**Fix direction:** Pass callbacks into `chat.create()` and `input.create()` at construction time: `on_close`, `on_cancel`, `on_submit`. The coordinator passes its own functions down; UI modules call them without knowing who they are.

### GAP-04: stream.lua hard-requires UI edge modules
**Spec:** architecture.md §2 — "Dependencies flow inward: edge → orchestration → data — never the reverse."
**Location:** `stream.lua:16–17`
**Finding:** `stream.lua` (orchestration) requires `ui/spinner` and `ui/render` (edge) at module level. This is orchestration → edge, the reverse of the allowed direction.
**Impact:** stream.lua cannot be tested without the UI layer present. Creates a potential cycle: init → stream → render → config → stream.
**Fix direction:** Pass `spinner` and `render` (or their relevant functions) into `stream.send()` via a callbacks table or `ui_callbacks` argument.

### GAP-05: Context window tables duplicated in two modules
**Spec:** performance.md §5 — "One fact, one place — duplicated data sources are a maintenance cost disguised as a performance optimization."
**Location:** `conversation.lua:36–66`, `models.lua:22–53`
**Finding:** Both files contain identical `model_context_windows` and `provider_context_windows` tables. The performance doc explicitly describes this as a violation: "Context windows hardcoded in conversation.lua AND fetched from models.dev in models.lua is two sources of truth."
**Impact:** Adding a new model requires editing both files. Drift causes silent wrong-window truncation — the exact scenario the spec warns about.
**Fix direction:** Remove the duplicate tables from `conversation.lua`. The `_get_context_window()` function already accepts a `registry_lookup` parameter — always pass `models.get_context_window` from the coordinator.

### GAP-06: Two hardcoded provider lists that must be manually synced
**Spec:** api-contracts.md §5 — "Derive registries from registrations, not from hardcoded lists."
**Location:** `providers/init.lua:52`, `config.lua:321`
**Finding:** `providers/init.lua` has `local builtins = { "ollama", "anthropic", "bedrock", "openai_compat" }`. `config.lua` has a separate `local known = { ollama = true, ... }` fallback. The spec says: "Two lists that must be kept in sync manually is zero sources of truth."
**Impact:** Adding a provider requires editing both files. Forgetting one causes silent omission from the picker or a false validation failure.
**Fix direction:** `providers/init.lua:M.list()` should discover providers via filesystem glob or a registration mechanism. `config.lua`'s fallback list should be removed or replaced with a call to `providers.list()`.

### GAP-07: Errored flag not re-checked inside vim.schedule in on_exit
**Spec:** code-conventions.md §3 — "Check [errored] before every error callback AND in the success path (on_exit with code 0 can arrive after a stream parser error)."
**Location:** `providers/anthropic.lua:268–303`, `providers/bedrock.lua:176–221`, `providers/openai_compat.lua:236–269`
**Finding:** All three providers check `errored` synchronously before `vim.schedule()` in `on_exit`, but do NOT re-check inside the scheduled block. A race is possible: `stdout` fires an error between the sync check and the async dispatch, causing both `on_error` and `on_done` to fire.
**Impact:** Under specific timing conditions, a corrupt response (empty assistant message) could be appended to the conversation after an error was already reported.
**Fix direction:** Add `if errored then return end` as the first line inside every `vim.schedule(function() ... end)` block in `on_exit` handlers.

---

## Significant — Real violations that undermine stated principles

### GAP-08: config.get() returns mutable M.defaults before setup()
**Spec:** architecture.md §3 — "Never hand out mutable references to owned state."
**Location:** `config.lua:250`
**Finding:** `config.get()` returns `resolved or M.defaults`. Before `setup()` is called, `resolved` is nil, so callers receive a direct reference to the shared `M.defaults` table. Any mutation silently corrupts the defaults for all subsequent callers.
**Impact:** Pre-setup mutations to the returned table are invisible and permanent. The `freeze()` mechanism only applies to `resolved`, not `M.defaults`.
**Fix direction:** Return `vim.deepcopy(M.defaults)` when `resolved` is nil, or freeze `M.defaults` at module load time.

### GAP-09: conversation.append() does not enforce role-alternation invariant
**Spec:** api-contracts.md §7 — "conversation.append() must validate the structural invariant... no two consecutive assistant messages."
**Location:** `conversation.lua:153–162`
**Finding:** `append()` validates individual message structure (role, content) but does NOT check whether the new message's role is the same as the last message's role. If a retry bug causes `on_done` to fire twice, two consecutive assistant messages enter the conversation.
**Impact:** The Anthropic API requires strict alternation and rejects duplicate roles with a cryptic 400 error. The `terminal_fired` guard in `stream.lua` currently prevents this, but `conversation.lua` should not rely on a guard in a different module.
**Fix direction:** Add to `append()`: `if #state.messages > 0 and state.messages[#state.messages].role == message.role then error(...) end`.

### GAP-10: config.set() does not warn on per_conversation setting changes
**Spec:** api-contracts.md §8 — "config.set() should respect these categories — warn or no-op if a per-conversation setting is changed mid-conversation."
**Location:** `config.lua:257–290`
**Finding:** The `LIFECYCLE` table correctly categorizes settings. The `per_send` branch warns during streaming. But there is no `per_conversation` branch — changing `default_provider` or `system_prompt` mid-conversation silently takes effect with no notification.
**Impact:** Users changing `default_provider` mid-conversation get no feedback that it won't take full effect until `/clear`.
**Fix direction:** Add `elseif lifecycle == "per_conversation" then vim.notify("... start a new conversation for it to take effect", INFO)`.

### GAP-11: stream.lua state mutations bypass set_state()
**Spec:** architecture.md §7 — "Every function begins by asserting that the current state is among its legal preconditions."
**Location:** `stream.lua:267` (`state.cancel_fn = cancel_fn`), `stream.lua:158` (`state.ttft_ms = ttft_ms`)
**Finding:** The module defines `set_state()` as the single state mutation point and has a disciplined state machine with explicit transitions. But two lines bypass it by directly mutating the state table.
**Impact:** Breaks the state machine discipline. A future log/debug hook on `set_state()` would miss these mutations.
**Fix direction:** Route `cancel_fn` and `ttft_ms` through `set_state()` or a dedicated setter, or restructure `_do_send` to pass them through the transition.

### GAP-12: lifecycle.lua directly mutates init.lua's ui_state table
**Spec:** architecture.md §3 — "State has exactly one owner — everyone else gets snapshots or callbacks."
**Location:** `lifecycle.lua:16–22`
**Finding:** `lifecycle.lua` receives a reference to `init.lua`'s internal `state.ui` table and directly sets `is_open = false`, `chat_winid = nil`, etc. The state owner (`init.lua`) is bypassed.
**Impact:** State can be mutated from two places, making it harder to trace state changes. A validation or notification hook in `init.lua` would be bypassed.
**Fix direction:** Pass a `reset_fn` callback into `lifecycle.setup()` instead of the raw state table. `init.lua` provides the reset function.

### GAP-13: config.lua calls vim.fn and vim.notify (editor API in pure data module)
**Spec:** architecture.md §6 — "No module outside ui/ touches a buffer or window directly. The data model must be testable without a running Neovim instance."
**Location:** `config.lua:201` (`vim.fn.getcwd`), `config.lua:202` (`vim.fn.filereadable`), `config.lua:208,242` (`vim.notify`), `config.lua:340,348` (`vim.fn.stdpath`)
**Finding:** config.lua is a pure data module that makes multiple editor API calls: filesystem checks, user notifications, and path resolution.
**Impact:** config.lua cannot be tested without a running Neovim instance. Side effects (notifications) are embedded in data logic.
**Fix direction:** Accept resolved paths as arguments. Return status values instead of calling `vim.notify`. Let the caller (`init.lua`) handle I/O and notifications.

### GAP-14: Tests mock provider interface instead of vim.system
**Spec:** testing.md §2 — "Mock at the process boundary — vim.system — and nowhere else."
**Location:** `tests/stream_guard_spec.lua:24–25,63–64,103–104,145–146,182–183,219–220,253–254,275–276`, `tests/pipeline_spec.lua:366–384`
**Finding:** All 8 tests in `stream_guard_spec.lua` and 1 test in `pipeline_spec.lua` construct a `mock_provider` with a hand-written `chat` function. This mocks the provider interface, not `vim.system`.
**Impact:** Tests may pass even if the provider-to-stream translation is broken. The callback guard is a state-machine concern that could be tested as a pure function.
**Fix direction:** Extract the callback guard logic into a testable pure function. For integration tests, mock `vim.system` to produce the relevant SSE/NDJSON sequences through a real provider.

### GAP-15: Test calls underscore-prefixed internal function
**Spec:** testing.md §3 — "Never call underscore-prefixed internal functions in tests."
**Location:** `tests/history/store_spec.lua:344–376`
**Finding:** Test directly calls `store._rebuild_index()`. The public behavior (auto-rebuild via `list()`) is already tested at line 313.
**Impact:** Test is coupled to implementation. Renaming or inlining `_rebuild_index` breaks the test even though behavior is unchanged.
**Fix direction:** Delete the `_rebuild_index()` test. Its behavior is already covered by the "rebuilds index when missing" test via the `list()` public API.

---

## Moderate — Real deviations that are lower-severity

### GAP-16: Scattered mutable locals instead of single state table
**Spec:** code-conventions.md §1 — "Mutable state lives in a single `local state = {}` table at the top of the owning module."
**Location:** `init.lua:44` (`local initialized`), `pipeline.lua:34` (`local last_request`), `config.lua:10` (`local resolved`), `state.lua:10,14` (`local _state`, `local _custom_dir`), `providers/init.lua:8` (`local providers`), `ui/thinking.lua:21` (`local block_ranges`), `history/init.lua:8` (`local config`)
**Finding:** Seven modules use scattered mutable locals instead of a single `state = {}` table. The convention exists to prevent test-pollution and make state visible when scanning the file header.
**Impact:** Lower severity — functional correctness is not affected, but test isolation and code readability are degraded.
**Fix direction:** Consolidate mutable locals into a `local state = {}` table at each module's top. E.g., `init.lua`: `state.initialized = false`; `pipeline.lua`: `pstate.last_request = {}`.

### GAP-17: Six files exceed 300-line threshold
**Spec:** code-conventions.md §4 — "If a file grows past 300 lines, it is probably doing two things."
**Location:** `config.lua` (351), `init.lua` (345), `providers/anthropic.lua` (322), `ui/chat.lua` (311), `models.lua` (305), `conversation.lua` (304)
**Finding:** Six files exceed the 300-line guideline.
**Impact:** Suggests these modules may have accumulated multiple concerns. `config.lua` is the most over-limit and has the most violations (project config loading, validation, path resolution, lifecycle management).
**Fix direction:** `config.lua`: extract `load_project_config()` to a separate module. `init.lua`: move `_setup_code_buffer_tracking()` to `lifecycle.lua`. Others are borderline and may not need splitting.

### GAP-18: Unjustified lazy requires (no cycle, no comment)
**Spec:** code-conventions.md §6 — "Use the lazy require pattern only when a direct require would create a circular dependency. Document why with a comment."
**Location:** `providers/anthropic.lua:300` (requires `util.tokens` inline), `ui/render.lua:119` (requires `config` inline), `ui/input.lua:107` (requires `config` inline), `history/init.lua:14` (requires `config` inline)
**Finding:** Four in-function requires that are not justified by a circular dependency and have no cycle-breaking comment.
**Impact:** Dependencies are hidden from readers scanning the file header. Refactoring tools miss these call sites.
**Fix direction:** Move to top-level `local mod = require(...)` declarations. If the require is intentionally deferred (e.g., render.lua captures config once per response), add a comment explaining why.

### GAP-19: pcall wrapping internal functions and JSON decode
**Spec:** code-conventions.md §7 — "Use pcall when calling buffer or window APIs on resources the user might have closed. Do not pcall your own internal functions."
**Location:** `providers/bedrock_codec.lua:124,127,129,139`, `health.lua:38`, `providers/init.lua:18,44,54`, plus ~10 instances of `pcall(vim.json.decode, ...)` across providers, models, history, and state modules
**Finding:** pcall is used around `vim.json.decode`, `vim.base64.decode`, `vim.inspect`, `require`, and internal function calls. By the strict reading of the convention, these are not Neovim API calls on closeable resources.
**Impact:** This is a pragmatic gray area. JSON decode can fail on malformed input from external sources (network, disk), which is structurally similar to the "external state you cannot predict" exception. The `health.lua` and `providers/init.lua` pcalls around `require` are more clearly justified (provider may not exist). Severity is low.
**Fix direction:** For JSON decode of external data (network responses, files on disk), pcall is arguably correct — add a comment noting the external-data justification. For `health.lua:38` wrapping an internal call, refactor to check initialization state explicitly.

### GAP-20: Leaf UI modules pull config directly instead of receiving it as arguments
**Spec:** code-conventions.md §9 — "Leaf modules take explicit, named arguments. They do not receive a deps bag."
**Location:** `ui/render.lua:119`, `ui/thinking.lua:11,91`, `ui/chat.lua:6`
**Finding:** Three leaf UI modules require `config` and call `config.get()` internally instead of receiving the relevant config slice as a parameter.
**Impact:** UI modules have a hidden dependency on the config module's shape. They cannot be tested with custom config without mocking the global config.
**Fix direction:** Pass config slices as function parameters. E.g., `render.begin_response(bufnr, { show_thinking = true })` instead of reading config internally.

### GAP-21: Async test assertions not guarded with timeout check
**Spec:** testing.md §6 — "Guard every async assertion with a timeout check — treat a timeout as a skip, not a failure."
**Location:** `tests/providers/contract_spec.lua:148–153,288–296,363–372,478–497`, `tests/render/thinking_spec.lua:155–180`
**Finding:** Multiple `vim.wait` calls are followed by unconditional assertions without `if result ~= nil then` guards. If `vim.wait` times out in CI, these tests fail instead of skipping.
**Impact:** Potential CI flakiness on slow machines. The spec explicitly calls this out as an anti-pattern that "teaches the team to ignore red builds."
**Fix direction:** Wrap all post-`vim.wait` assertions in `if result ~= nil then ... end` guards.

### GAP-22: health.lua has provider-specific branching
**Spec:** architecture.md §4 — "Nothing above providers/ may know about URL schemes, auth mechanisms, SSE formats, or error taxonomies."
**Location:** `health.lua:56–118`
**Finding:** `health.lua` contains explicit `if provider_name == "ollama"` / `"anthropic"` / `"openai_compat"` / `"bedrock"` branches for diagnostic checks. A code comment acknowledges this: "Provider-specific checks here are acceptable for diagnostics."
**Impact:** Adding a fifth provider requires editing `health.lua`. The comment shows awareness but the violation remains.
**Fix direction:** Add a `health_check()` function to the provider interface. `health.lua` calls `provider.health_check(config)` uniformly.

### GAP-23: Bedrock error messages missing actionable next steps
**Spec:** code-conventions.md §8 — "Every error message must include the specific failure and a concrete next step."
**Location:** `providers/bedrock_codec.lua:142` ("Bedrock stream exception"), `providers/bedrock.lua:182` ("Bedrock request failed (curl exit N)"), `providers/bedrock_codec.lua:191` ("Bedrock API error")
**Finding:** Three Bedrock error messages provide the failure but no actionable next step. Compare with Anthropic's messages which include specific guidance like "Check that ANTHROPIC_API_KEY is set correctly."
**Impact:** Users hitting Bedrock errors must diagnose the problem without guidance from the error message.
**Fix direction:** Append actionable context: "Check AWS_BEARER_TOKEN_BEDROCK and region configuration" for stream exceptions; "Check network connection and AWS region" for curl failures.

### GAP-24: events.md line numbers are stale (all 7 events)
**Spec:** events.md documents `Location:` with specific line numbers for each event.
**Location:** All 7 events in `docs/events.md`
**Finding:** Every documented line number is wrong. Offsets range from 7–12 lines. Additionally, `AiChatProviderChanged` documents the wrong file entirely (`init.lua:310` vs actual `pickers.lua:76`). All payload shapes are correct.
**Impact:** Developers following the docs to find event sources land in the wrong place. The `AiChatProviderChanged` case is the worst — completely wrong file.
**Fix direction:** Update all line numbers in `docs/events.md`. For `AiChatProviderChanged`, correct the file reference to `pickers.lua`. Consider removing exact line numbers (they drift) and using function-name references instead.

### GAP-25: AiChatPanelClosed has undocumented second firing path
**Spec:** api-contracts.md §6 — "Document every User autocmd name and the exact shape of its data payload."
**Location:** `lifecycle.lua:22` (fires `AiChatPanelClosed`), `docs/events.md` (documents only `init.lua` as source)
**Finding:** `AiChatPanelClosed` fires from both `init.lua:143` (explicit close) and `lifecycle.lua:22` (external window/buffer destruction). The docs mention only the first source. Double-firing is guarded (lifecycle sets `is_open = false`, init checks it), but the second trigger path is undocumented.
**Impact:** Users building integrations on this event may not realize it fires on external close, not just `M.close()`.
**Fix direction:** Add a note to `docs/events.md` that this event fires on both explicit close and external window destruction.

### GAP-26: _rebuild_index() is synchronous and reads all conversation files
**Spec:** performance.md §1 — "Never block the main loop — one synchronous stall of 50ms is worse than a thousand 0.01ms inefficiencies."
**Location:** `history/store.lua:185–203`
**Finding:** `_rebuild_index()` calls `vim.fn.glob()` + `vim.fn.readfile()` on every `.json` file synchronously. Called from `M.list()` when the index is missing or corrupt. For 100+ conversations, this blocks the main loop.
**Impact:** Low probability (only fires on corrupt/missing index), but when it fires the stall can be hundreds of milliseconds.
**Fix direction:** Ensure `index.json` is always written atomically so rebuild is never needed in normal operation (already partially done). For the fallback, use `vim.uv.fs_*` async APIs or defer with `vim.schedule`.

---

## What's Clean

The following areas fully comply with their respective specs:

- **Callback cardinality enforcement** (api-contracts.md §1): `stream.lua` correctly implements both a `terminal_fired` flag and a generation counter. Post-cancel callbacks are silenced reliably. ✅
- **Provider shape validation at load time** (api-contracts.md §2): `providers/init.lua:23–29` validates all four required functions. Missing functions error loudly at load time. ✅
- **Response shape normalization** (api-contracts.md §3): All four providers normalize `on_done` responses with zero-valued defaults for `usage`. No nil `usage` or `content` fields escape the provider boundary. ✅
- **Cancel semantics** (api-contracts.md §4): Generation counter is incremented before state mutation. Post-cancel `vim.schedule` callbacks are silenced by generation check. Ordering is correct. ✅
- **Buffer modifiable toggle** (code-conventions.md §5): `render.lua` implements `with_modifiable(bufnr, fn)` with pcall guarantee. Used consistently for all buffer writes. ✅
- **Function naming conventions** (code-conventions.md §2): No `handle_*` or `process_*` function names found. All extracted functions are named for their effect. ✅
- **TTFT measurement** (performance.md §2): Timestamps at `pipeline.send()` entry and first `on_chunk`. Included in the `AiChatResponseDone` event payload. ✅
- **Deep copies in conversation.get()** (performance.md §3): Returns `vim.deepcopy(state)`. No unnecessary deep copies on hot paths. ✅
- **No O(n²) in chunk path** (performance.md §4): Chunk processing uses delta-only operations. Window iteration for auto-scroll is O(windows) ≈ O(1). ✅
- **Disk I/O at transition boundaries** (performance.md §6): History saves on `on_done` only. No disk I/O during streaming. ✅
- **No stale cached IDs** (performance.md §7): Auto-scroll iterates `nvim_list_wins()` per chunk. Stored IDs are validated before use and cleared by lifecycle autocmds. ✅
- **Parameterized provider contract tests** (testing.md §5): `contract_spec.lua` runs 6 scenarios against all 4 providers. Adding a provider adds one entry to the test matrix. ✅
- **Error path test coverage** (testing.md §7): All 9 canonical error codes tested. Error paths outnumber happy paths across the test suite. ✅
- **Real filesystems and buffers in tests** (testing.md §8): Tests use real tmpdirs, real file writes, and real buffers. Only `vim.system` is mocked. ✅
- **Streaming state machine** (architecture.md §7): Explicit named states (idle, streaming, retrying), transition table with load-time validation, `transition()` function with precondition assertions. Well-structured. ✅
- **All event payload shapes match documentation** (events.md): Despite stale line numbers, every payload shape in the code matches the documented contract exactly. ✅
- **No autocmds fired from ui/ files** (architecture.md §6): All event emissions originate from orchestration/coordination modules, not edge UI modules. ✅

---

## Resolved

| Gap | Resolved date | Reference |
|-----|---------------|-----------|
| *(none yet)* | | |
