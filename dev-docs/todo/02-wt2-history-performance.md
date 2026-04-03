# WT2: History Performance

**Branch:** `gap/history-performance`
**Phase:** 1 (parallel, no dependencies)
**Gaps:** GAP-05

---

## bell-labs Prompt

```
You are working in a git worktree branched from `dev`.

## Task
Address GAP-05 from `dev-docs/spec-compliance-gaps.md`.

## Scope (ONLY these files)
- `lua/ai-chat/history/store.lua` — primary target
- `tests/history/store_spec.lua` — update/extend tests
- `dev-docs/spec-compliance-gaps.md` — mark resolved

## What to do
`store.list()` reads every JSON conversation file synchronously on every
save (via `_prune()`). Replace with a lightweight `index.json` maintained
alongside conversation files. The index contains
`{ id, title, timestamp, provider, model }` per entry. `write()` updates
the index entry. `list()` reads only the index. `_prune()` uses the index
for age/count decisions. Add an `_rebuild_index()` for corruption recovery
that scans all files and regenerates.

## Constraints
- Read `docs/performance.md` §1 — this is the exact violation it describes.
- The index must be crash-safe: write to a temp file and rename (atomic on POSIX).
- Existing `list()` callers must see no API change.
- Run `make test` and `make lint`.

## Persona consultation
Consult John Carmack on whether the index approach is sufficient or whether
an in-memory LRU cache with lazy disk write would be better for the
access pattern (write-heavy, list-on-browse-only).
```
