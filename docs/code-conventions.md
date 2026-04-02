# Code Conventions

**Thesis:** Every convention exists to serve the reader — the person who will modify this code six months from now without the author's context. If a convention cannot be explained in terms of a concrete failure it prevents, it does not belong here.

---

## Principles

### 1. Every module owns its state, and no one else touches it

**Rule:** Mutable state lives in a single `local state = {}` table at the top of the owning module. Other modules access state through public functions. Never hold a reference to another module's internal table and mutate it.

**Rationale:** State ownership is the architecture. When it breaks, symptoms appear far from the cause. The ownership map — config → `config.lua`, conversation → `conversation.lua`, streaming → `stream.lua`, UI refs → `init.lua` — is load-bearing documentation.

**Violation:** A new feature checks whether streaming is active by reading `stream.state.active` directly. A refactor of stream's internals breaks the feature silently. The right thing: call `stream.is_active()` — one line, and the dependency is through a contract, not a data structure.

---

### 2. Name functions for what they return or do, never for when they are called

**Rule:** A function extracted from a callback body is named for its effect (`finalize_response`, `append_assistant_message`), not for its trigger (`handle_done`, `process_event`). Callback *parameter names* (`on_done`, `on_chunk`) describe slots. Extracted functions describe actions.

**Rationale:** In a callback-heavy async codebase crossing four modules (pipeline → stream → provider → render), every intermediate function named `handle_X` forces the reader to read the body to understand the flow. Names like `finalize_response` or `classify_error` can be followed without opening the file.

**Violation:** The `on_done` logic from `pipeline.send()` is extracted into `handle_done()`. Six months later someone sees `handle_done()` and must read the body to learn it appends to conversation, saves history, records cost, and updates the winbar.

---

### 3. The errored flag pattern is a concurrency contract — use it exactly or not at all

**Rule:** In provider implementations, initialize `errored = false` at function scope. Check it before every error callback AND in the success path (`on_exit` with code 0 can arrive after a stream parser error). Set it before calling the callback, not after. This is not defensive programming — it is a correctness requirement.

**Rationale:** `vim.system` can invoke `on_exit` after `on_stderr` has already fired. Without the flag, the UI shows two error messages, or worse, `on_done` fires after `on_error` and appends a corrupt assistant message to the conversation.

**Violation:** A new provider author writes the happy path first, adds error handling later, and forgets to gate `on_done` with `if errored then return end`. A malformed final SSE frame triggers `on_error`, then `on_exit` fires with code 0 and triggers `on_done`. The conversation now contains both an error and a garbage response.

---

### 4. One module, one file, one concern — and init.lua is the public door, not the junk drawer

**Rule:** Each `init.lua` re-exports a curated public interface for its directory. It reads like a table of contents. If you are adding code to `init.lua` that is more than delegation, you need a new file. If a file grows past 300 lines, it is probably doing two things.

**Rationale:** `errors.lua` is 70 lines and does one thing. That is the model. At the file level, the test is: can you describe what this module does in one sentence without the word "and"?

**Violation:** Someone adds model-specific parameter validation to `providers/init.lua` — checking context windows, adjusting temperature ranges, mapping model aliases. The registry file is now 200 lines and does three things. The validation belongs in individual provider modules or a dedicated `providers/params.lua`.

---

### 5. Protect the buffer with the modifiable toggle, and treat it as a transaction bracket

**Rule:** The chat buffer is `modifiable = false` by default. Every write sets it `true` before and `false` after, treating the pair as BEGIN/COMMIT. The flag must be restored even if the write fails. Wrap buffer writes in a helper that guarantees restoration via pcall.

**Rationale:** This prevents the user from typing into the chat buffer and corrupting the conversation display. A code path where an error skips the reset leaves the buffer permanently modifiable — a silent, user-visible corruption.

**Violation:** A new render helper checks buffer validity, sets modifiable to true, then calls `nvim_buf_set_lines`. The buffer was closed between the check and the write. The error propagates, modifiable is never reset, and the user can now type into the chat buffer. The fix: wrap the write in pcall and reset modifiable unconditionally afterward.

---

### 6. Lazy require is for breaking cycles — do not use it for startup performance

**Rule:** Use the lazy require pattern (`local mod; local function get_mod() ...`) only when a direct `require` at file scope would create a circular dependency. Document *why* with a comment. If there is no cycle, use a plain `require` at the top of the file.

**Rationale:** Neovim's `require` caches modules after first load — the second call is a table lookup. The performance difference is unmeasurable. But a lazy require buried in a helper function hides the dependency from any reader scanning the top of the file.

**Violation:** A developer adds `util/markdown.lua` and uses the lazy require pattern in `render.lua` because "that's how the codebase does it." There is no circular dependency. A future refactor that moves markdown utilities does not find all call sites by grepping for `require("ai-chat.util.markdown")` because the actual require is inside a closure.

---

### 7. pcall belongs at the boundary between your code and Neovim APIs that can fail due to external state

**Rule:** Use `pcall` when calling buffer or window APIs on resources the user might have closed (`nvim_buf_set_lines`, `nvim_win_set_cursor`). Do not pcall your own internal functions. If internal code throws, that is a bug — surface the stack trace, do not swallow it.

**Rationale:** `pcall` says "I do not know if this will work and I am prepared to swallow the failure." That is appropriate for external state you cannot predict. It is not appropriate for your own logic. Wrapping internal calls in pcall turns bugs into silent data corruption.

**Violation:** Someone wraps `conversation._truncate_to_budget()` in pcall because "it might fail if the token estimator gets weird input." Now when the token estimator returns nil instead of a number, truncation silently does nothing, the payload exceeds the context window, and the API returns a 400 with no indication the real problem is three layers down.

---

### 8. Write error messages for the user who will read them, not the developer who wrote them

**Rule:** Every error message that reaches the user (via `vim.notify` or the chat buffer) must include the specific failure and a concrete next step. Internal error codes (`rate_limit`, `auth`, `network`) are for retry logic — they are not for humans.

**Rationale:** "Request failed" is useless. "Authentication failed — check that ANTHROPIC_API_KEY is set and valid" is useful. The provider knows the context; the generic error handler does not. Error messages should be written at the provider boundary where the context exists.

**Violation:** A provider's HTTP call returns a 403. The error callback passes `{ code = "auth", message = "Forbidden" }`. The stream module sees `auth`, decides it is fatal, and shows the user "Error: Forbidden". The user has no idea whether their API key is wrong, expired, or whether they hit the wrong endpoint.

---

### 9. Dependency injection via deps tables belongs in orchestrators only — leaf modules take explicit arguments

**Rule:** Use a `deps` table parameter only in orchestration modules (`pipeline.lua`) that coordinate multiple subsystems. Leaf modules (providers, conversation, render) take explicit, named arguments. They do not receive a deps bag.

**Rationale:** `pipeline.send(text, ui_state, deps)` makes data flow visible and orchestration testable. But if this pattern spreads to leaf modules, you cannot tell what anything depends on without reading the whole function body. Explicit named parameters at the leaf level are worth more than a generic bag.

**Violation:** Someone refactors `render.append()` to take a `deps` table containing config, conversation, and ui_state. Now render — which should only know about buffers and text — has a dependency on the conversation module's data shape, blowing a hole in the architectural boundary between UI and data.

---

## Anti-Patterns

### The Cargo-Cult Deep Copy
Adding `vim.deepcopy()` to every return value "for safety" without understanding which callers actually mutate the result. Deep copies are O(n) operations. They belong at trust boundaries where external callers receive mutable state. Internal module-to-module calls that immediately serialize or read the result do not need copies — they need discipline.

### The Scattered Mutable Local
Mutable state added as `local last_error = nil` halfway through a file instead of in the module's `state` table. Not reset between tests. Not visible when scanning the module header. The symptom: test case 7 fails only when run after test case 4.

### The Invisible Dependency
A `require` buried inside a function body, undiscoverable by grepping the file header. In a codebase where most modules declare dependencies at the top, hidden requires cause refactoring tools and human readers to miss call sites.

### The Swallowed Exception
A `pcall` around internal logic that silently discards the error and continues with default behavior. The original bug becomes invisible, and the user sees a symptom (API error, corrupt display) far from the cause (nil return from a utility function).

### The Vague Error Message
An error that tells the user *what happened* ("Forbidden") without telling them *what to do about it* ("check that ANTHROPIC_API_KEY is set and valid"). The developer who writes the error handler usually tests the happy path and never reads their own error messages.

---

## Reference: Configuration

`config.resolve(opts)` deep-merges user opts with `config.defaults` using `vim.tbl_deep_extend("force", ...)`. After `setup()`, all modules call `config.get()` — never read defaults directly.

**Per-project config** (`.ai-chat.lua` in cwd): only `system_prompt`, `default_provider`, `default_model`, `temperature`, and `providers.*` are applied. Keymaps, UI, log, and history settings are silently ignored from project config.

`config.set("chat.thinking", true)` works at runtime via dot-path.
