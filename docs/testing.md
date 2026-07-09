# Testing

**Thesis:** Tests exist to make change safe — they verify the contracts we promise and the invariants we depend on, nothing more, nothing less.

*Perspectives: Kent Beck (TDD, test what you fear, courage to change) and Martin Fowler (test taxonomy, refactoring safety, cost of change). Both agree that tests are an economic decision: test the things where bugs are expensive. They disagree slightly on coverage philosophy — Beck tests what he fears, Fowler tests at boundaries. For this codebase, we follow Beck's instinct (test state machines and async contracts aggressively) with Fowler's structure (clear test taxonomy with contract tests as the highest-value layer).*

---

## Principles

### 1. Test contracts, not implementations

The provider contract test (`contract_spec.lua`) is the model for all testing in this project. It parameterizes across all four providers and verifies: validate() works, auth failures produce `code="auth"`, streaming produces chunks and usage, network failures are retryable. It does not test how each provider parses SSE — that's an implementation detail.

**Rationale:** Implementation changes are free if the contract holds. If tests are coupled to implementation, every refactor breaks tests, and developers stop refactoring. Contract tests break only when behavior changes — which is exactly when you want them to break.

**Violation:** A test that asserts the Anthropic provider sends exactly 7 curl arguments in a specific order. The contract is: it calls curl, it streams, it returns chunks and usage. The number of arguments is an implementation detail.

### 2. State machines are the highest-value test targets

The stream lifecycle state machine has more test coverage than any other module, and it should. State machines have the most subtle bugs: illegal transitions, stale callbacks, double-terminal events, cancel-during-retry races. The `stream_guard_spec.lua` tests verify all of these.

**Rationale:** A bug in a state machine can corrupt the plugin's core loop — the user sends a message and gets no response, or gets two responses, or the spinner never stops. These bugs are hard to reproduce and hard to debug. Aggressive testing of the state machine prevents them.

**Violation:** Adding a new stream phase without adding transition tests for every event in that phase. If the phase exists, every legal and illegal transition from that phase must be tested.

### 3. Mock at the boundary, never in the middle

Mock `vim.system` to simulate provider behavior. Mock the filesystem for state persistence tests. Never mock internal modules — if `pipeline.lua` needs a conversation module, give it the real `conversation.lua`. Internal mocks create tests that pass when the code is broken.

**Rationale:** The boundary between the plugin and the outside world (network, filesystem, Neovim API) is where non-determinism enters. Mock there. Internal module interactions are deterministic — test them with real modules or don't test them at all.

**Violation:** Mocking `conversation.build_provider_messages()` inside a pipeline test. If the pipeline test needs messages, let conversation build them. Mocking it hides bugs where pipeline and conversation disagree about the message format.

### 4. Test in the real environment

Tests run inside headless Neovim (`nvim --headless`), not in a standalone Lua interpreter. This means tests exercise real `vim.api`, real `vim.system`, real `vim.json`. The test environment IS the production environment minus the terminal.

**Rationale:** A test that passes in vanilla Lua but fails in Neovim is worse than no test — it provides false confidence. Neovim's Lua runtime has specific behaviors (vim.schedule, vim.wait, buffer APIs) that a standalone interpreter cannot replicate.

**Violation:** Running tests with `lua` or `luajit` directly. These tests cannot call `vim.api`, cannot create buffers, and cannot test anything that matters about a Neovim plugin.

### 5. Each test file owns one concern

`conversation_spec.lua` tests conversation state management. `stream_guard_spec.lua` tests stream callback cardinality. `config_spec.lua` tests configuration resolution and validation. `contract_spec.lua` tests the provider contract. Tests do not cross concern boundaries.

**Rationale:** When a test fails, the filename tells you where the bug is. If `config_spec.lua` fails, the bug is in config resolution, not in provider streaming. Clear ownership makes failures actionable.

**Violation:** A test in `conversation_spec.lua` that also verifies the provider got the right curl arguments. That's a provider contract test — it belongs in `contract_spec.lua`.

### 6. Write the test BEFORE the fix

When a bug is found, the first step is writing a failing test that reproduces it. The test goes in the appropriate spec file. Then the fix is written. Then the test passes. The test stays forever — it's a regression guard.

**Rationale:** A bug without a test will recur. A test written after the fix might not actually test the bug — it might test the fix, which is a different thing. Writing the test first ensures it fails for the right reason.

**Violation:** Fixing a stream cancellation race condition and writing no test. The bug will return when someone refactors the state machine, because no test guards the specific transition.

### 7. Isolate test state completely

Every `before_each` starts with a clean state: fresh config resolution, fresh conversation, saved/restored environment variables, temp directories for filesystem tests. Every `after_each` tears down: restore `vim.system`, restore env vars, delete temp files.

**Rationale:** Test order dependence is the most insidious testing bug. A test that passes alone but fails in a suite (or vice versa) is worse than no test. Complete isolation prevents this category entirely.

**Violation:** A state test that writes to `~/.local/share/ai-chat/state.json` instead of a temp directory. It reads state from a previous test run and produces non-deterministic results.

---

## What to Test

| Target | Test type | Example |
|---|---|---|
| Provider contracts | Parameterized contract test | `contract_spec.lua`: validate, auth error, streaming, network error, request body |
| Stream state machine | Behavioral/state tests | `stream_guard_spec.lua`: cardinality guard, cancel safety, phase transitions |
| Conversation invariants | Unit tests | `conversation_spec.lua`: append validation, truncation, restore with bad data |
| Config resolution | Unit tests | `config_spec.lua`: defaults, overrides, deep merge, validation |
| Persisted state | Round-trip tests | `state_spec.lua`: save/load, corrupt file handling |
| Error classification | Unit tests | `pipeline_spec.lua`: retryable vs fatal categorization |

## What NOT to Test

| Skip | Why |
|---|---|
| UI rendering details | Buffer line content changes with every design tweak. Test the render contract (begin_response returns append/finish/error), not the specific lines written. |
| Exact curl arguments | Implementation detail. The contract is: the provider calls curl and streams. How many headers it sends is not a contract. |
| Private `_functions` | Functions prefixed with `_` are internal. Test through the public interface. If a private function is complex enough to need its own test, it should be a public function in a utility module. |
| Highlight groups | Declarative definitions that link to Neovim built-ins. No logic to test. |
| vim.ui.select interactions | User-facing pickers depend on the Neovim UI framework. Test the data preparation (picker items), not the picker display. |

---

## Violations

### V1: Tests coupled to implementation

A test that breaks when you refactor internal code without changing behavior. The fix is: test through the public contract, not through internal function calls.

### V2: Non-deterministic tests

Tests that depend on timing, network access, or filesystem state from previous runs. Use `vim.wait()` with explicit conditions for async tests. Use temp directories for filesystem tests. Never depend on real network access.

### V3: Test coverage theater

Adding tests for trivial getters, highlight definitions, or simple table lookups to inflate coverage numbers. Every test should guard against a bug that would matter if it shipped.

### V4: Missing regression tests

Fixing a bug without adding a test. The bug will return. The person who re-introduces it will not know it was a bug before. The test is the institutional memory.
