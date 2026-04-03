# WT6: Render Pipeline

**Branch:** `gap/render-pipeline`
**Phase:** 2 (after Phase 1 merges)
**Gaps:** GAP-08, GAP-12, GAP-23

---

## bell-labs Prompt

```
You are working in a git worktree branched from `dev` AFTER Phase 1 is merged
(specifically after WT1's stream.lua changes and WT5's config.lua changes).

## Task
Address GAP-08, GAP-12, and GAP-23 from `dev-docs/spec-compliance-gaps.md`.

## Scope
- `lua/ai-chat/ui/render.lua` — all three gaps
- `lua/ai-chat/stream.lua` — GAP-08: change `stream_render.finish()` call to pass pre-computed cost
- `lua/ai-chat/pipeline.lua` — GAP-08: cost computation stays here, passes to stream
- Relevant test files
- `dev-docs/spec-compliance-gaps.md` — mark resolved

## What to do

**GAP-08:** Move cost estimation out of `render.lua:finish()`. Compute
cost in `pipeline.on_done` (already partially done at line 137–139) and
pass it through `stream.lua` to `render.finish()` as a pre-computed
string. Remove `config`, `models`, and `costs` requires from render.lua.

**GAP-12:** Extract a `with_modifiable(bufnr, fn)` helper that wraps all
buffer writes in `render.lua`. The helper sets modifiable=true, pcalls the
function, always resets modifiable=false, then re-raises on error. Replace
all 6+ toggle pairs.

**GAP-23:** Capture `config.get().chat` once at the top of
`begin_response()` and close over it in the `append` function. Remove
the per-chunk `config.get()` call.

## Constraints
- Read `docs/architecture.md` §2 and §5 — render is a UI leaf, must not
  do orchestration work.
- Read `docs/code-conventions.md` §5 — the pcall-protection rule.
- The `stream_render.finish()` signature change must be coordinated with
  `stream.lua`'s call site.
- Run `make test` and `make lint`.

No persona consultation needed — the spec direction is unambiguous.
```
