# WT5: Provider Config

**Branch:** `gap/provider-config`
**Phase:** 2 (after Phase 1 merges)
**Gaps:** GAP-06, GAP-09, GAP-10, GAP-19, GAP-22, GAP-24

---

## bell-labs Prompt

```
You are working in a git worktree branched from `dev` AFTER Phase 1 is merged.

## Task
Address GAP-06, GAP-09, GAP-10, GAP-19, GAP-22, and GAP-24 from
`dev-docs/spec-compliance-gaps.md`.

## Scope
- `lua/ai-chat/providers/init.lua` — GAP-06 (shape validation), GAP-10 (derived list)
- `lua/ai-chat/config.lua` — GAP-09 (immutable get), GAP-10 (remove hardcoded list), GAP-22 (lifecycle categories)
- `lua/ai-chat/providers/anthropic.lua` — GAP-19 (actionable error messages)
- `lua/ai-chat/providers/bedrock.lua` — GAP-19 + GAP-24 (error messages + rename)
- `lua/ai-chat/providers/openai_compat.lua` — GAP-19 (actionable error messages)
- `lua/ai-chat/init.lua` — GAP-22 (set_thinking guard)
- Relevant test files
- `dev-docs/spec-compliance-gaps.md` — mark resolved

## What to do

**GAP-06:** After `require` in `providers/init.lua:M.get()`, validate that
the module exports `validate`, `preflight`, `list_models`, and `chat` as
functions. Error loudly on missing functions.

**GAP-09:** Make `config.get()` return a read-only proxy (not a deepcopy —
performance.md rejects that). Use a metatable with `__index` that reads
from `resolved` and `__newindex` that errors. Nested tables need recursive
proxying or accept shallow protection with a documented limitation.

**GAP-10:** `providers.list()` returns `vim.tbl_keys()` of the loaded
cache. `config.validate()` calls `providers.exists()` instead of
maintaining a hardcoded `valid_providers` array. Handle the potential
circular require (config → providers) with a lazy require + comment.

**GAP-19:** Add actionable error messages to anthropic ("Check
ANTHROPIC_API_KEY"), bedrock ("Check AWS_BEARER_TOKEN_BEDROCK"), and
openai_compat ("Check API key and endpoint URL"). Follow ollama's pattern.

**GAP-22:** Add lifecycle category metadata to config keys. `config.set()`
warns when changing a per-send setting while `stream.is_active()` is true.

**GAP-24:** Rename `_process_stream_buffer` → `_decode_bedrock_frames`,
`_handle_anthropic_event` → `_dispatch_event` in bedrock.lua.

## Constraints
- Read `docs/api-contracts.md` §2, §5, §8 and `docs/performance.md`
  accepted-tradeoffs table before making design choices.
- The read-only proxy for GAP-09 must not break `config.get().chat.thinking`
  reads (very common pattern). Test this explicitly.
- Run `make test` and `make lint`.

## Persona consultation
Consult Joshua Bloch and Ken Thompson on the GAP-09 read-only proxy vs
deepcopy tradeoff. The spec rejects deepcopy-on-every-access but the
read-only proxy adds metatable complexity. Is there a simpler approach
(e.g., freeze-on-resolve, copy-on-set)?
```
