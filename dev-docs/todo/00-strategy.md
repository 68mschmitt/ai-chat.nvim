# Parallel Worktree Strategy for Spec Compliance Gaps

**Created:** 2026-04-02
**Source:** `dev-docs/spec-compliance-gaps.md` (22 remaining gaps: GAP-03 through GAP-24)

---

## Completion Status

| Phase | Worktrees | Status | Commit |
|---|---|---|---|
| Phase 1 | WT1, WT2, WT3, WT4 | ✅ Complete | `765be68` |
| Phase 2 | WT5, WT6 | ✅ Complete | `904fe24` |
| Phase 3 | WT7 | ⏳ Pending | — |

**Resolved:** 20 of 24 gaps (GAP-01 through GAP-24, excluding GAP-13, 14, 16, 17)
**Remaining:** GAP-13 (test internals), GAP-14 (lazy requires), GAP-16 (file splitting), GAP-17 (pcall config.get)

---

## Overview

The remaining gaps cluster into 7 conflict-free worktree groups based on which source files each gap touches. Each worktree gets its own `bell-labs` agent session with a self-contained prompt. Merge ordering prevents conflicts.

---

## File Conflict Map

| Hotspot File | Gaps That Touch It |
|---|---|
| `stream.lua` | GAP-03, 04, 08, 14, 21 |
| `ui/render.lua` | GAP-08, 12, 14, 16, 17, 23 |
| `config.lua` | GAP-09, 10, 22 |
| `providers/init.lua` | GAP-06, 10 |
| `bedrock.lua` | GAP-16, 19, 24 |
| `init.lua` | GAP-14, 16, 22 |

---

## Worktree Grouping

### Phase 1 — Zero cross-worktree file overlap, fully parallel

| Worktree | Gaps | Files Touched | Persona Value |
|---|---|---|---|
| **WT1: stream-state-machine** | GAP-03, GAP-04, GAP-21 | `stream.lua`, `pipeline.lua` | High — state machine design, cancel semantics |
| **WT2: history-performance** | GAP-05 | `history/store.lua` | Medium — index file vs cache tradeoffs |
| **WT3: new-files-only** | GAP-07, GAP-15 | `tests/providers/contract_spec.lua` (new), `docs/events.md` (new) | Medium — test design, API documentation |
| **WT4: data-utils** | GAP-11, GAP-18, GAP-20 | `conversation.lua`, `models.lua`, `spinner.lua`, `log.lua`, `costs.lua`, `health.lua` | Low — mechanical consolidation |

### Phase 2 — Merge Phase 1 first, then run these in parallel

| Worktree | Gaps | Files Touched | Persona Value |
|---|---|---|---|
| **WT5: provider-config** | GAP-06, GAP-09, GAP-10, GAP-19, GAP-22, GAP-24 | `providers/init.lua`, `config.lua`, `anthropic.lua`, `bedrock.lua`, `openai_compat.lua`, `init.lua` | High — API design, read-only proxy vs deepcopy |
| **WT6: render-pipeline** | GAP-08, GAP-12, GAP-23 | `ui/render.lua`, `stream.lua` (1 line: finish call) | Medium — boundary design |

### Phase 3 — Merge everything, then run last (broadest touch surface)

| Worktree | Gaps | Files Touched | Notes |
|---|---|---|---|
| **WT7: code-hygiene** | GAP-13, GAP-14, GAP-16, GAP-17 | 10+ files | Must go last — touches nearly everything |

---

## Merge Order

```
Phase 1 (parallel):   WT1, WT2, WT3, WT4  →  merge all to dev
Phase 2 (parallel):   WT5, WT6            →  merge to dev
Phase 3 (sequential): WT7                 →  merge to dev (rebase on final state)
```

---

## Setup Commands

```bash
# From the repo root, create worktrees
git worktree add ../ai-chat-wt1-stream   -b gap/stream-state-machine
git worktree add ../ai-chat-wt2-history  -b gap/history-performance
git worktree add ../ai-chat-wt3-new      -b gap/contract-tests-and-docs
git worktree add ../ai-chat-wt4-data     -b gap/data-utils
# Phase 2 (create after phase 1 merges)
git worktree add ../ai-chat-wt5-provider -b gap/provider-config
git worktree add ../ai-chat-wt6-render   -b gap/render-pipeline
# Phase 3 (create after phase 2 merges)
git worktree add ../ai-chat-wt7-hygiene  -b gap/code-hygiene
```

---

## Persona Consultation Points

Only 3 of the 7 worktrees have genuine design ambiguity worth consulting personas on:

1. **WT1** — State machine encoding (Rich Hickey vs Dijkstra: data-oriented vs formal)
2. **WT5** — Read-only config proxy (Joshua Bloch vs Ken Thompson: safety vs simplicity)
3. **WT7** — File-splitting seams (Brian Kernighan: where are the natural module boundaries)

The rest are mechanical — the spec already dictates the direction. Invoking personas on those would be performative, not productive.

---

## Prompt Files

Each worktree has a corresponding prompt file in this directory:

| File | Worktree | Phase |
|---|---|---|
| `01-wt1-stream-state-machine.md` | WT1 | 1 |
| `02-wt2-history-performance.md` | WT2 | 1 |
| `03-wt3-contract-tests-and-docs.md` | WT3 | 1 |
| `04-wt4-data-utils.md` | WT4 | 1 |
| `05-wt5-provider-config.md` | WT5 | 2 |
| `06-wt6-render-pipeline.md` | WT6 | 2 |
| `07-wt7-code-hygiene.md` | WT7 | 3 |

---

## Why This Works

- **Phase 1 worktrees have zero shared files** — verified by file-level conflict analysis.
- **Phase 2 has one minor overlap**: WT6 touches `stream.lua` (1 line: the `finish()` call), which WT1 refactored. Trivial merge.
- **WT7 goes last** because GAP-14 (lazy requires) and GAP-16 (file splitting) touch nearly every file in the project. Running them after all other changes are stable avoids N-way merge conflicts.
- **Each prompt explicitly lists its file scope** so bell-labs (and worker-bee) won't accidentally touch files owned by another worktree.
