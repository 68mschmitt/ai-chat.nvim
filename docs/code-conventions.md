# Code Conventions

**Thesis:** Code is read ten times for every once it is written; every convention in this project optimizes for the reader who did not write it, at 2 AM, tracing a bug through async callbacks.

*Perspectives: Brian Kernighan (clarity, simplicity, the reader is always the audience) and Linus Torvalds (pragmatism, no unnecessary abstraction, reject cleverness). Both agree that readability is the cardinal virtue. They would disagree on tone — Kernighan would explain patiently, Torvalds would reject the patch. We follow Kernighan's style in documentation and Torvalds' standard in code review: if it's not clear, it does not ship.*

---

## Principles

### 1. Every module opens with a header stating purpose and ownership

The first lines of every `.lua` file are a doc comment block that states: what this module does, what state it owns, and what it does not touch. This is the reader's first stop when they encounter a module they didn't write.

**Rationale:** A programmer tracing a bug needs to know in five seconds whether they're in the right file. The header is the signpost.

**Violation:** A module that opens with `local M = {}` and no comment. The reader must scan 200 lines to understand what this module is responsible for.

### 2. Name functions for what they do, not how they do it

`conversation.append()` appends a message. `stream.cancel()` cancels a stream. `errors.classify()` classifies an error. If a function name requires a comment to explain its purpose, rename the function.

**Rationale:** The name is the most-read documentation for any function. A good name makes the call site self-documenting. A bad name generates comments that rot.

**Violation:** A function named `process_data()` that builds provider messages, applies truncation, and notifies the user. It should be three functions with three names, or it should be named `build_provider_messages()` if that's what it actually does.

### 3. Error messages tell the user what happened AND what to do

Every error message surfaced to the user must contain: (1) what went wrong, in plain language, and (2) what the user can do about it. Provider errors include the specific action: "Set ANTHROPIC_API_KEY environment variable." Network errors include: "Is Ollama running? Start it with `ollama serve`."

**Rationale:** An error message that says "Request failed" wastes the user's time. An error message that says "Ollama not detected at localhost:11434. Start it with `ollama serve` or switch provider." respects it.

**Violation:** `callbacks.on_error({ code = "network", message = "Connection refused" })` — missing the actionable guidance. Compare with the actual codebase: `"Ollama request failed. Is Ollama running at " .. host .. "? Start it with 'ollama serve'."`.

### 4. Functions fit in one screen; modules fit in one head

No function exceeds ~50 lines. If it does, it's doing too much. Extract the sub-operations into named functions — the names become documentation. No module exceeds ~350 lines. If it does, it owns too many concerns and should be split.

**Rationale:** If you have to scroll to understand a function, the function is too complex to debug reliably. The screen is the unit of comprehension.

**Violation:** A 150-line function that handles SSE parsing, error classification, retry logic, and usage tracking. Each of these is a separate concern. The stream module delegates error classification to `errors.lua` and rendering to the render factory — this is the right decomposition.

### 5. No abstraction without simplification

Every abstraction layer must make the code simpler for the reader, not just more "organized." If an abstraction adds indirection without reducing complexity, delete it. Provider adapters are justified because they absorb provider-specific complexity. A `BaseProvider` class that all adapters inherit from is not justified — it adds indirection without reducing the code in any adapter.

**Rationale:** Abstraction for the sake of pattern compliance is complexity masquerading as organization. The test is: can the reader understand this code faster with the abstraction or without it?

**Violation:** Creating a `ProviderBase` metatable with default implementations that every provider overrides anyway. This adds a file and an indirection layer with zero reduction in per-provider code. The current pattern — each provider is an independent module implementing 4 functions — is simpler and just as correct.

### 6. Flat is better than nested

Directory structure: two levels maximum (`lua/ai-chat/providers/`). Control flow: avoid nesting beyond 3 levels of indentation. If you're inside `if → for → if`, extract the inner logic into a named function.

**Rationale:** Deep nesting, whether in files or in control flow, forces the reader to maintain a mental stack. Flat structures are scannable. Named functions replace indentation with intention.

**Violation:** `lua/ai-chat/providers/anthropic/streaming/sse/parser.lua` — four directory levels for one parser. The actual codebase puts the Anthropic SSE parsing inline in `anthropic.lua` because it's 30 lines and doesn't warrant a separate file, let alone a separate directory tree.

### 7. `pcall` at boundaries, `error()` at invariants

Use `pcall` when calling Neovim APIs or external code that might fail for environmental reasons (buffer deleted, window closed, API changed). Use `error()` for programming errors that represent violated invariants — `conversation.append()` with an invalid role should never silently succeed.

**Rationale:** Environmental failures are expected and must be handled gracefully. Programming errors are bugs and must be surfaced loudly so they get fixed. Mixing these two categories — swallowing programming errors with pcall, or crashing on environmental failures — produces either silent corruption or fragile plugins.

**Violation:** Wrapping `conversation.append()` in pcall "just in case." If append receives invalid data, that's a bug in the caller. The error should propagate. Conversely, `vim.api.nvim_exec_autocmds` is wrapped in pcall because the autocmd may not exist — that's an environmental condition, not a bug.

### 8. One formatting standard, enforced by tooling

stylua with the project's `.stylua.toml` (120 col, 4-space indent, Unix line endings, double quotes). Formatting is not a code review discussion. Run `make format` before committing. Run `make lint` in CI. No exceptions.

**Rationale:** Style debates consume engineering time with zero value. An automated formatter ends the debate permanently. The specific choices (4 spaces, 120 columns) are less important than the fact that they are consistent and enforced.

**Violation:** A PR that mixes tabs and spaces because the contributor didn't run stylua. This is caught by `make lint` in CI and should never reach review.

---

## Violations

### V1: Clever code

Code that uses obscure Lua features, metatable tricks, or dense one-liners to save lines at the expense of readability. The reader is a tired maintainer at 2 AM, not a Lua golf competitor. If it takes more than 5 seconds to understand a line, rewrite it.

### V2: Silent swallowing

Using `pcall` around code that should raise errors, hiding bugs behind "defensive programming." If `conversation.append()` is called with `nil` content, that's a bug. Let it crash. Fix the caller.

### V3: God modules

A module that grows past 400 lines because "it's all related." `init.lua` was refactored to extract `pipeline.lua` when the send logic grew too large. This is the pattern: when a module outgrows one head, extract the coherent sub-concern.

### V4: Orphaned comments

Comments that describe what the code does instead of why. `-- Append message to conversation` above `conversation.append(message)` adds noise. Comments should explain non-obvious decisions: `-- Temperature is not allowed when thinking is enabled (Anthropic API constraint)` is valuable because the "why" is not obvious from the code.

### V5: Abbreviations in public interfaces

Module-internal shorthand is fine (`conv`, `cfg`, `msg` in local scope). Public function names and parameter names use full words: `conversation`, `config`, `message`. The public interface is documentation; abbreviations are tax on the reader.
