# WT7: Code Hygiene

**Branch:** current branch (in-place)
**Phase:** 3 (all prior phases merged; execute in current branch)
**Gaps:** GAP-13, GAP-14, GAP-16, GAP-17

> **Status:** ⏳ Pending — execute in current branch (no worktree needed)

---

## bell-labs Prompt

```
You are working in the current branch. All Phase 1 and Phase 2 worktrees
have already been merged.

## Task
Address GAP-13, GAP-14, GAP-16, and GAP-17 from `dev-docs/spec-compliance-gaps.md`.

## Scope
- Broad — these gaps touch 10+ files. This phase runs last; all prior work is merged.

## What to do

**GAP-14 (do first):** Move all non-cycle-breaking lazy requires to file
top in: `init.lua`, `stream.lua`, `ui/render.lua`, `ui/thinking.lua`,
`ui/chat.lua`, `conversation.lua`. For any that genuinely break a cycle,
add a `-- Lazy: breaks <A> → <B> → <A> cycle` comment. Investigate each
one; most are not cycle-breaking.

**GAP-17:** Remove pcall wrappers around `config.get()` in `thinking.lua`,
`render.lua`, and `chat.lua`. Call directly. This pairs naturally with
GAP-14's require hoisting in the same files.

**GAP-13:** Refactor tests to stop calling underscore-prefixed internals:
- `conversation_spec.lua`: test `_truncate_to_budget` through `build_provider_messages`
- `pipeline_spec.lua`: test `_get_context_window` through `build_provider_messages`
- `state_spec.lua`: replace `_reset` with `package.loaded` reload

**GAP-16:** Split oversized files:
- `init.lua` (474 lines): extract picker/browser functions into `lua/ai-chat/pickers.lua`
- `bedrock.lua` (439 lines): extract decoder into `lua/ai-chat/providers/bedrock_decoder.lua`
- `render.lua` (418 lines): extract code-block navigation into `lua/ai-chat/ui/code_blocks.lua`

## Constraints
- Work is done in the current branch. All prior phases are already merged.
- Run `make test` and `make lint` after EACH gap to catch regressions early.
- File splits must not change any public API — only internal `require` paths change.

## Persona consultation
Consult Brian Kernighan on the file-splitting boundaries: where are the
natural seams in each oversized file? The goal is modules that can be
understood in isolation, not arbitrary line-count reduction.
```
