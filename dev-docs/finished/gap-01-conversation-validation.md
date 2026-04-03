# GAP-01: `conversation.append()` Performs Zero Validation

**Status:** Not started
**Spec reference:** `docs/api-contracts.md` §7
**Primary file:** `lua/ai-chat/conversation.lua` (lines 90–94)
**Related gaps:**
- GAP-02 (callback cardinality — the root cause of the double `on_done` bug; fix separately)
- GAP-13 (tests call internal functions — the new validation tests should use only the public API)

---

## Problem Statement

`conversation.append()` is a bare `table.insert(state.messages, message)`. It accepts any value — nil fields, wrong types, illegal roles. Invalid data enters the conversation and propagates silently until an external API rejects it, three modules and two async boundaries away from the corruption point.

The spec is explicit:

> *"Reject invalid mutations at the point of insertion, not three function calls later when an API rejects the result."*
> — api-contracts.md §7

### Concrete failure mode

A retry bug fires `on_done` twice. Two consecutive assistant messages enter the conversation. `build_provider_messages` sends them. The Anthropic API requires strict user/assistant alternation and returns a 400. The user sees "invalid request" with no clue the real problem is a corrupted history.

### Scope clarification

This validation is a **tripwire**, not a fix. It collapses the distance between corruption and discovery to zero. The actual cause — the stream layer firing `on_done` twice — is GAP-02 and must be fixed separately. Both are necessary: GAP-02 prevents the bug; GAP-01 ensures that if a similar bug occurs in the future, it surfaces immediately rather than propagating.

---

## Expert Review

Three experts reviewed the original plan. Their consensus drove four material changes:

| Change | Rationale | Consensus |
|---|---|---|
| **Sequence validation removed from `append()`** | Message alternation is a provider protocol constraint, not a data model invariant. The architecture spec says "nothing provider-specific leaks above `providers/`." Move to `build_provider_messages()` or the pipeline layer. | Beck + Hickey agree; Bloch dissents (considers alternation a data model property). Went with the majority — this codebase has multiple providers with different constraints. |
| **`restore()` switched to lenient** | History files are user data that degrades over time. Rejecting a 200-message conversation because message 47 is corrupt is punishing the user. Filter bad messages, keep good ones, log warnings. | Unanimous. |
| **Content rules refined by role** | Assistant content may legitimately be empty (cancelled stream, thinking-only response). User content must be non-empty (the user typed something). | Bloch raised; Beck + Hickey concurred. |
| **Extra fields: explicit rationale** | Document *why* extra fields are ignored — `conversation.lua` is a data module, not a schema validator. Prevents future contributors from adding `usage` validation and breaking the architecture boundary. | Bloch recommendation. |

Full expert responses archived in project history.

---

## Call Sites

There are exactly two places that call `conversation.append()`:

| Location | Role appended | Data source |
|---|---|---|
| `pipeline.lua:73` | `"user"` | User input text (always a string) |
| `pipeline.lua:128–135` | `"assistant"` | Provider response (`response.content`, `response.usage`, etc.) |

`conversation.restore()` (`conversation.lua:74–82`) bulk-loads messages from history JSON. It does not call `append()` — it assigns the whole array. Validated separately with lenient semantics.

---

## Validation Rules

### `append()` — structural only (reject with `error()`)

These are properties of messages *as data*, independent of any provider:

1. **Type check:** `message` must be a table.
2. **Role present:** `message.role` must be a non-empty string.
3. **Role legal:** `message.role` must be one of `"user"` or `"assistant"`. System prompts have a dedicated path via `build_provider_messages()` — appending `"system"` to the history is always a bug.
4. **Content type:** `message.content` must be a string.
5. **Content non-empty for user:** If `role == "user"`, content must be non-empty (the user typed something). If `role == "assistant"`, empty string is allowed (cancelled stream, thinking-only response).
6. **Extra fields silently accepted:** `timestamp`, `usage`, `model`, `thinking` are metadata. `conversation.lua` is a data module, not a schema validator — it does not know or care what fields a provider response includes.

### What `append()` does NOT validate

**Message alternation (no consecutive same-role check).** This is a provider protocol constraint (Anthropic requires strict alternation; other providers may not). Per the architecture spec, provider-specific concerns do not leak above `providers/`. If an alternation safety net is needed, it belongs in `build_provider_messages()` or the pipeline, where provider protocol knowledge already lives.

### `restore()` — lenient recovery

1. Validate each message structurally (same rules as `append()`, minus the non-empty-content-for-user rule — historical messages may have different constraints).
2. **Keep valid messages, skip invalid ones.**
3. Log a warning per skipped message with index and reason.
4. Log a summary: "restored N of M messages (K skipped)".
5. If *all* messages are invalid, the conversation is empty — equivalent to starting fresh.

---

## Task Breakdown

### 1. Define `AiChatMessage` type formally
- [ ] Add a `---@class AiChatMessage` annotation at the top of `conversation.lua` with fields: `role`, `content`, `timestamp?`, `usage?`, `model?`, `thinking?`.
- Currently referenced in 12 type annotations across the codebase but never formally defined.

### 2. Implement `validate_message()` internal helper
- [ ] Create a local `validate_message(message)` function in `conversation.lua`.
- [ ] Returns `true` on success, `false, reason_string` on failure.
- [ ] Checks: type is table, role is string and in `{"user", "assistant"}`, content is a string.
- [ ] Include actual values in the reason string (e.g., `"role must be 'user' or 'assistant', got: 47"`).

### 3. Add validation to `append()`
- [ ] Call `validate_message()`. On failure, call `error()` with the reason string.
- [ ] Additionally check: if `role == "user"` and `content == ""`, call `error()`.
- [ ] No sequence checks — that is a consumer concern.

### 4. Add lenient validation to `restore()`
- [ ] Iterate messages. Validate each with `validate_message()`.
- [ ] Keep valid messages, skip invalid ones.
- [ ] Log a warning per skipped message: index, role (if present), and reason.
- [ ] Log a summary if any were skipped.

### 5. Add tests through the public API only
- [ ] Test valid append: user then assistant, check `message_count()` and `get()`.
- [ ] Test valid append: assistant with empty content (cancelled stream case).
- [ ] Test rejection: wrong type (`append("string")`), missing role, missing content, invalid role.
- [ ] Test rejection: user message with empty content.
- [ ] Test system role rejection: `append({ role = "system", content = "..." })`.
- [ ] Test restore with mix of valid and invalid messages — verify valid ones are kept.
- [ ] Test restore logs warnings for skipped messages.
- [ ] All tests use only public functions. Do NOT call `_validate_message()` directly (per GAP-13 / testing.md §3).

### 6. Verify no callers break
- [ ] `pipeline.lua:73` always passes `{ role = "user", content = text }` — safe.
- [ ] `pipeline.lua:128–135` — verify `response.content` is always a string across all four providers. Empty string is now allowed for assistant role.
- [ ] `conversation_spec.lua` test calls — update any that relied on invalid input.
- [ ] Run `make test` to confirm nothing breaks.

### 7. Update the spec-compliance-gaps document
- [ ] Move GAP-01 to the Resolved section with date and commit reference.

---

## Design Decisions (Resolved)

| # | Question | Decision | Rationale |
|---|---|---|---|
| D1 | Error mechanism for invalid `append()` | `error()` | These are precondition violations — programming bugs, not user errors. All three experts agree. Include actual values in the message. |
| D2 | Restore validation strictness | **Lenient** — skip bad messages, keep good ones, log warnings | Unanimous expert consensus. History files are user data. Partial data has partial value. Don't destroy it. |
| D3 | Allow `"system"` in append? | Reject | System prompt has a dedicated path via `build_provider_messages()`. Appending it to history is always a bug. |
| D4 | Validate extra fields? | Ignore | `conversation.lua` is a data module, not a schema validator. Whitelisting fields would couple it to provider response shapes, violating the architecture boundary. |
| D5 | Sequence validation in `append()`? | **No** — removed | Message alternation is a provider protocol constraint. The architecture spec prohibits provider-specific logic above `providers/`. If needed, enforce in `build_provider_messages()` or the pipeline. (Beck + Hickey; Bloch dissents.) |
| D6 | Empty assistant content? | **Allowed** | Cancelled streams and thinking-only responses produce empty `content`. User content must be non-empty. (Bloch raised, unanimous agreement.) |

---

## Files to Modify

| File | Change |
|---|---|
| `lua/ai-chat/conversation.lua` | Add `AiChatMessage` class, `validate_message()`, validation in `append()`, lenient validation in `restore()` |
| `tests/conversation_spec.lua` | Add validation tests (valid appends, rejection cases, restore recovery) |
| `dev-docs/spec-compliance-gaps.md` | Move GAP-01 to Resolved |

---

## Acceptance Criteria

- [ ] `conversation.append({ role = "user", content = "hello" })` succeeds.
- [ ] `conversation.append({ role = "assistant", content = "hi" })` succeeds.
- [ ] `conversation.append({ role = "assistant", content = "" })` succeeds (cancelled stream).
- [ ] `conversation.append("not a table")` raises an error mentioning the actual type.
- [ ] `conversation.append({ content = "no role" })` raises an error.
- [ ] `conversation.append({ role = "user" })` raises an error (no content).
- [ ] `conversation.append({ role = "user", content = "" })` raises an error (user content non-empty).
- [ ] `conversation.append({ role = "admin", content = "x" })` raises an error mentioning "admin".
- [ ] `conversation.append({ role = "system", content = "x" })` raises an error.
- [ ] `conversation.restore()` with a mix of valid and invalid messages keeps the valid ones.
- [ ] `conversation.restore()` logs warnings for skipped messages.
- [ ] `make test` passes.
- [ ] No existing tests break.
