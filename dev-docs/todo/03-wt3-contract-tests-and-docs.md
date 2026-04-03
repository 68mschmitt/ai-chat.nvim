# WT3: Contract Tests and Docs

**Branch:** `gap/contract-tests-and-docs`
**Phase:** 1 (parallel, no dependencies)
**Gaps:** GAP-07, GAP-15

---

## bell-labs Prompt

```
You are working in a git worktree branched from `dev`.

## Task
Address GAP-07 and GAP-15 from `dev-docs/spec-compliance-gaps.md`.

## Scope (ONLY new files — zero existing file modifications except the gaps doc)
- `tests/providers/contract_spec.lua` — NEW: parameterized provider contract tests
- `docs/events.md` — NEW: autocmd event documentation
- `dev-docs/spec-compliance-gaps.md` — mark resolved

## What to do

**GAP-07:** Create `tests/providers/contract_spec.lua` — one parameterized
test suite that runs against all four providers (ollama, anthropic, bedrock,
openai_compat) with `vim.system` mocked to return provider-appropriate
responses. Test:
1. `validate(valid_config)` returns true
2. Auth failure → `on_error` with `code = "auth"`
3. Streamed response → `on_chunk` fires, `on_done` has content + usage
4. Network failure → `on_error` with `code = "network"`, `retryable = true`
5. The request body sent to curl has the correct structure (system prompt placement, temperature handling)

Read `docs/testing.md` §2 and §5 for mock strategy and contract test design.
Read each provider file to understand its curl command structure and SSE format.
Mock `vim.system` per the pattern in `tests/pipeline_spec.lua`.

**GAP-15:** Create `docs/events.md` documenting all 7 autocmd events with
their exact payload shapes. Read the source locations listed in the gap.
Note the `AiChatResponseDone` redundant `usage` key — document the current
shape, add a note that `usage` is deprecated in favor of `response.usage`.

## Constraints
- Do NOT modify any existing source or test files.
- Test harness: `describe`/`it`/`assert` are globals, do NOT require anything.
- Run `make test` and `make lint`.

## Persona consultation
Consult Kent Beck on contract test granularity: should each provider ×
scenario be a separate `it()` block (36 tests, very specific failures) or
should each scenario be one `it()` that loops providers (7 tests, less
specific but less duplication)?
```
