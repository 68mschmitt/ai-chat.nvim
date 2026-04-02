# Testing

**Thesis:** A test earns its place by giving you courage to change the code tomorrow — if it punishes refactoring instead of enabling it, delete it.

---

## Principles

### 1. Test the boundaries where data transforms, not the wiring that connects them

**Rule:** Test functions that take input and return output: conversation building, error classification, token estimation, cost calculation, config validation. Do not test that `pipeline.send()` calls modules in the right order — that is restating the implementation as an assertion.

**Rationale:** The most valuable tests in this codebase — conversation state, error classification, token/cost utilities — share a trait: they test a function that takes input and returns output. These tests are fast, deterministic, and scream when something breaks. Pipeline wiring tests break on every refactor and tell you nothing about whether the pieces work.

**Violation:** A test that mocks `conversation.build_provider_messages`, mocks `stream.send`, mocks `render.append`, then asserts `pipeline.send()` calls them in sequence. That test breaks every time you restructure the pipeline and catches zero real bugs.

---

### 2. Mock at the process boundary — vim.system — and nowhere else

**Rule:** Every provider eventually calls `vim.system` to shell out to curl. That is the one legitimate mock point — the line between code you own and the outside world. Mocking anything else (provider internals, conversation methods, config accessors) means testing a fiction.

**Rationale:** When you mock `vim.system`, assert *what you sent to curl* — the JSON body structure, the headers, the URL. The provider's entire job is translation: conversation → HTTP request → response → callbacks. If you only assert "on_done was called," you miss bugs in the translation.

**Violation:** A provider test mocks `vim.system` to return canned success and only asserts `on_done_was_called == true`. That test passes even if the system prompt is in the wrong place (Anthropic rejects this), or temperature is sent with thinking mode on (Anthropic rejects this too). The translation is where the bugs live.

---

### 3. Test through public APIs — never call underscore-prefixed internal functions in tests

**Rule:** If `_truncate_to_budget` is an implementation detail of `build_provider_messages`, test it through `build_provider_messages`. If you cannot exercise a code path through the public function, that is a design signal — either the path is dead or the module's API is too narrow.

**Rationale:** Testing internal functions couples your tests to the implementation. When you refactor internals — splitting a function, changing a strategy — tests break even though behavior is unchanged. The test suite becomes a reason not to refactor, which is the opposite of its purpose.

**Violation:** `conversation_spec.lua` tests `_truncate_to_budget` directly. If you later change the truncation strategy or split the function differently, those tests break even though `build_provider_messages` still returns correct results. Test the contract: given a message list exceeding the budget, the returned messages fit, the system prompt is preserved, and the most recent messages are kept.

---

### 4. Never test Neovim's API — test your decisions about what to tell Neovim's API

**Rule:** You do not need to verify that `nvim_buf_set_lines` puts lines in a buffer. Test that your module *decides* to set the right lines, in the right order, with the right metadata. For UI modules too tightly coupled to the editor API, make them thinner until the logic is extractable — then test the logic.

**Rationale:** Your `thinking_spec` gets this right — it creates a real buffer, fills it with content, then tests whether `find_blocks` identifies the right line ranges. It tests your logic, not Neovim's buffer implementation. Full UI tests ("does the split open at the right width?") test Neovim's window management, not your code.

**Violation:** A test opens the chat panel, calls `nvim_win_get_width()`, resizes the terminal, and checks again. You are testing Neovim's window layout engine. When it fails in CI because headless Neovim reports different dimensions, you waste an afternoon on something that was never your bug.

---

### 5. Every provider must pass an identical contract test suite

**Rule:** Write one parameterized test suite that runs against each provider with `vim.system` mocked to return provider-appropriate responses. The contract is: given valid config, `validate` returns true. Given an auth failure response, `chat` calls `on_error` with `code = "auth"`. Given a streamed response, `on_chunk` fires and `on_done` receives the assembled result.

**Rationale:** Four providers implementing the same interface is a textbook case for contract testing. If someone adds a fifth provider, they should not have to reverse-engineer what to test by reading four separate test files. If the contract evolves, updating one shared suite catches inconsistencies across all providers.

**Violation:** Provider tests are bespoke per-provider with different assertion patterns. A new error code is tested for Anthropic but not Bedrock. The contract divergence is invisible until a user hits the untested path.

---

### 6. Guard every async assertion with a timeout check — treat a timeout as a skip, not a failure

**Rule:** For any test involving `vim.schedule` or timers, use `vim.wait` with a timeout. If the timeout fires, skip the assertion rather than failing. Log when a timeout skip occurs so you can detect tests that are always skipping.

**Rationale:** In headless Neovim, `vim.schedule` callbacks and timer-based retries are genuinely nondeterministic. A test that flakes in CI is worse than no test — it teaches the team to ignore red builds. The existing `if result ~= nil then assert...` pattern is correct. Make it a principle, not a convention someone discovered.

**Violation:** A stream retry test asserts `retry_count == 2` after `vim.wait(500, ...)`. On a fast machine it passes. In CI under load, the timer has not fired, `vim.wait` times out, and the assertion fails. The developer re-runs CI, it passes, they merge. Within a month, the team has a habit of re-running failures.

---

### 7. Test error paths more thoroughly than happy paths

**Rule:** The happy path — user sends message, gets response — is exercised every time someone uses the plugin. If it breaks, someone notices in seconds. Error paths — rate limits, network timeouts, auth failures, model not found — are exercised rarely and break silently. They need more test coverage, not less.

**Rationale:** The boundary between "retry this" and "stop and tell the user" is where real damage happens. Every canonical error code must have a test verifying its classification. Every provider must have tests for its error-mapping logic. The retryable/fatal distinction is not a nice-to-have — it determines whether the plugin hammers a failing API or surfaces a clear message.

**Violation:** A new error code `context_length_exceeded` is added, classified as retryable because "the server said 429-ish." No test. The plugin now retries the same too-long request three times before failing. One assertion would have caught it: `assert.is_false(errors.is_retryable("context_length_exceeded"))`.

---

### 8. Use real filesystems and real buffers — mock only the network

**Rule:** The filesystem and Neovim buffer API are fast, deterministic, and available in headless mode. Write to real tmpdirs. Create real buffers. Mock only `vim.system` (the network boundary). Everything else, use the real thing.

**Rationale:** Mocking `vim.fn.writefile` hides bugs — your test passes even if JSON serialization produces invalid output, because the mock never tried to write it. The real filesystem catches that. Real buffers catch modifiable-flag bugs. The only thing you cannot control in a test is the network. Mock that. Use everything else.

**Violation:** Mocking `vim.fn.readfile` in store tests "to avoid filesystem dependency." The test passes even if the JSON includes non-UTF8 bytes that would fail in production. The real filesystem would have caught it.

---

## Anti-Patterns

### The Wiring Test
A test that mocks every dependency of an orchestrator and asserts they were called in sequence. It restates the implementation as an assertion, breaks on every refactor, and catches no logic bugs. If you feel compelled to write a wiring test, the module is probably doing too much — extract the logic into a testable pure function.

### The Implementation-Coupled Test
Calling `M._internal_function()` directly in a test. When the implementation changes, the test breaks even though behavior is correct. Tests should exercise the public contract. If a code path is unreachable through public functions, the path is dead code.

### The Flaky Async Test
An assertion after `vim.wait` without a guard for timeout. It passes on fast machines, fails on slow ones, and teaches the team to ignore CI failures. Always guard: `if result ~= nil then assert... end`.

### The UI Pixel Test
Asserting on exact buffer contents, extmark positions, or window dimensions. These tests mirror the render implementation and break on any visual change. They punish the kind of change that should be cheapest.

### The Happy-Path-Only Suite
A test file that verifies the success case for every function but tests zero error paths. The happy path gets exercised naturally. Error paths are where the untested bugs hide.

---

## Reference: Test Harness

Tests use a **zero-dependency custom harness** (`tests/harness.lua`):

```lua
describe("group", function()
    before_each(fn)
    it("case", function()
        assert.equals(expected, actual)
        assert.is_true(val)
        assert.is_nil(val)
        assert.has_no.errors(fn)
        assert.is_not.equals(a, b)
    end)
end)
```

`describe`/`it`/`assert` are injected as globals by `tests/runner.lua` — do **not** `require` the harness in spec files.

To mock `vim.system` (used by all provider HTTP calls):

```lua
local original_system = vim.system
after_each(function() vim.system = original_system end)

vim.system = function(cmd, opts, on_exit)
    on_exit({ code = 0 })
    return { kill = function() end }
end
```

For async tests that use `vim.wait`, always guard assertions with `if result ~= nil then` because `vim.wait` may time out in CI.
