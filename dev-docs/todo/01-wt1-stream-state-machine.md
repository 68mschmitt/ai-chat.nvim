# WT1: Stream State Machine

**Branch:** `gap/stream-state-machine`
**Phase:** 1 (parallel, no dependencies)
**Gaps:** GAP-03, GAP-04, GAP-21

> **Status:** ✅ Complete — committed in Phase 1 (`765be68`, 2026-04-02)
>
> **What was done:**
> - GAP-04: Replaced scattered boolean flags with phase-based state machine (TRANSITIONS table, `transition()` function, phase-specific state records)
> - GAP-03: Verified — generation counter + phase transitions fully silence post-cancel callbacks
> - GAP-21: Added TTFT instrumentation via `vim.uv.hrtime()` in pipeline.lua → stream.lua; logged and included in AiChatResponseDone autocmd
>
> **Expert consultation:** Rich Hickey + Dijkstra both recommended phase-specific state records (replace entire state table on transition). Hickey favored transition table as data; Dijkstra favored guard assertions. Hybrid approach adopted: transition table for legality checks, logic stays in functions.

---

## bell-labs Prompt

```
You are working in a git worktree branched from `dev`.

## Task
Address GAP-03, GAP-04, and GAP-21 from `dev-docs/spec-compliance-gaps.md`.

## Scope (ONLY these files)
- `lua/ai-chat/stream.lua` — primary target
- `lua/ai-chat/pipeline.lua` — GAP-21 TTFT timestamp only
- `tests/stream_guard_spec.lua` — update/extend existing tests
- `dev-docs/spec-compliance-gaps.md` — mark gaps resolved

## What to do

**GAP-04 (do first — other gaps build on it):** Replace scattered boolean
flags in `stream.lua` state with a phase enum: `"idle" | "streaming" |
"retrying" | "cancelling"`. Assert legal phase preconditions at the top of
`send()`, `cancel()`, and `_do_send()`. Keep the existing `generation`
counter from the GAP-02 fix. Consult personas on: should `cancel_fn` and
`retry_timer` remain as separate fields or be folded into phase-specific
sub-states?

**GAP-03 (verify/close):** GAP-02's resolution added a generation counter
that already silences post-cancel callbacks. Verify the guard in `_do_send`
covers the `vim.schedule` window described in GAP-03. If any residual
exposure exists, fix it. If it's fully covered, mark it resolved with
explanation.

**GAP-21:** Add `vim.uv.hrtime()` instrumentation: timestamp at the top
of `pipeline.send()`, capture first-chunk time in the `on_chunk` guard.
Log TTFT via `util/log.lua`. Fire it in `AiChatResponseDone` data payload.

## Constraints
- Read `docs/architecture.md` §7 (state machine rule) and
  `docs/api-contracts.md` §4 (cancel semantics) before making design choices.
- Do NOT touch any file outside the scope list.
- Run `make test` and `make lint` before reporting done.
- Use StyLua formatting (120 col, 4-space indent, double quotes).

## Persona consultation
Consult Rich Hickey and Edsger Dijkstra on the state machine design:
should phase transitions be encoded as a transition table with assertions,
or as simple guard checks at function entry? The tension is between formal
correctness and Lua pragmatism.
```
