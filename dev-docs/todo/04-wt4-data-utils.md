# WT4: Data Utils

**Branch:** `gap/data-utils`
**Phase:** 1 (parallel, no dependencies)
**Gaps:** GAP-11, GAP-18, GAP-20

---

## bell-labs Prompt

```
You are working in a git worktree branched from `dev`.

## Task
Address GAP-11, GAP-18, and GAP-20 from `dev-docs/spec-compliance-gaps.md`.

## Scope (ONLY these files)
- `lua/ai-chat/conversation.lua` — GAP-11: unify context window lookup
- `lua/ai-chat/models.lua` — GAP-11: becomes authoritative source (+ GAP-18 state)
- `lua/ai-chat/ui/spinner.lua` — GAP-18: consolidate mutable locals into state table
- `lua/ai-chat/util/log.lua` — GAP-18: same
- `lua/ai-chat/util/costs.lua` — GAP-20: remove provider-specific branch
- `lua/ai-chat/health.lua` — GAP-20: reduce provider-name branching
- Relevant test files — update as needed
- `dev-docs/spec-compliance-gaps.md` — mark resolved

## What to do

**GAP-11:** Make `conversation._get_context_window()` call
`models.get_context_window()` as primary source, falling back to its
hardcoded table. Since `conversation.lua` is a pure data module, pass the
models lookup function as a parameter or accept the dependency with a
justifying comment.

**GAP-18:** In `spinner.lua`, `log.lua`, `store.lua`, and `models.lua`,
wrap scattered mutable module-level locals into a single
`local state = {}` table per file.

**GAP-20:** In `costs.lua`, replace `if provider == "ollama" then return 0`
with a provider-capability check (e.g., provider module exposes
`has_pricing = false`). For `health.lua`, if the refactor is small, have
each provider expose a `health_info()` function; otherwise document the
deviation and skip.

## Constraints
- Read `docs/architecture.md` §2 (pure data modules) before touching conversation.lua.
- GAP-18 in `store.lua` must not conflict with GAP-05 (different worktree
  handles store.lua performance). Only consolidate the state vars that exist
  today; don't change `list()` or `_prune()` behavior.
- Run `make test` and `make lint`.

No persona consultation needed — these are mechanical fixes.
```
