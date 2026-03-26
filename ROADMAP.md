# ai-chat.nvim — Roadmap

> **Note for AI agents:** This file is the source of truth for project
> progress. When you complete a roadmap item, **check it off immediately**
> (`- [ ]` → `- [x]`). Do not leave implemented features unmarked — the
> roadmap drifting out of sync with the codebase wastes future analysis time.
> If you pull work forward from a later milestone, mark it done in both
> places and add a note (e.g., *"done in v0.2"*).

## v0.1 — MVP (Target: 2 weeks)

Ship the smallest useful thing. Get it in people's hands.

### Scope

- [x] Toggle chat split (right side vertical split)
- [x] Input area with submit on `<CR>`
- [x] Send message, receive streamed response
- [x] One provider: Ollama (easiest to test, no API key)
- [x] `@buffer` context (send current buffer content)
- [x] `@selection` context (send visual selection)
- [x] Code block detection in chat buffer
- [x] `gY` — yank code block under cursor
- Basic markdown rendering:
  - [x] Headers rendered with highlight groups
  - [x] Code blocks with treesitter syntax highlighting (language injection)
  - [x] Bold text with concealed delimiters
- [x] Token usage display in message metadata
- [x] Cancel generation with `<C-c>`
- [x] `/clear` — clear conversation
- [x] `/model` — switch model via `vim.ui.select`
- [x] `/help` — list commands
- [x] Winbar with provider, model, message count
- [x] Error display inline in chat buffer
- [x] `setup()` with configuration validation
- [x] Vim help file (`:help ai-chat`)

**Ahead of schedule — pulled forward from v0.2 and v0.3:**

- [x] Diff-based code application (`ga` opens diff split) *(was v0.2)*
- [x] Conversation persistence — save/load as JSON *(was v0.2)*
- [x] `/save`, `/load`, `/new` slash commands *(was v0.2)*
- [x] `@diagnostics` context — LSP diagnostics *(was v0.2)*
- [x] `@diff` context — git diff *(was v0.2)*
- [x] `@file:path` context — arbitrary file inclusion *(was v0.3)*
- [x] Cost tracking and display in winbar — session-level *(was v0.2)*
- [x] `:AiChatCosts` — session cost summary *(was v0.2)*
- [x] Message navigation (`]]`, `[[`) *(was v0.2)*
- [x] Code block navigation (`]c`, `[c`) *(was v0.2)*
- [x] Quick actions: `<leader>ae` (explain), `<leader>af` (fix) *(was v0.2)*
- [x] Audit log (`:AiChatLog`) *(was v0.2)*
- [x] `gO` — open code block in new split buffer *(was v0.3)*
- [x] Input history recall (`<Up>`/`<Down>`) *(was v0.3)*
- [x] `:AiChatConfig` — show resolved config *(was v0.3)*
- [x] `:AiChatKeys` — show keybinding reference *(was v0.3)*

### Success Criteria

A user with Ollama installed can:
1. `:AiChat` to open the panel
2. Type a question about their code with `@buffer`
3. Read a syntax-highlighted response
4. Yank a code block from the response
5. Close the panel with `q`

---

## v0.2 — Essential Polish (Target: 2 weeks after v0.1)

### Scope

**Structural (do first):**

- [x] Extract `conversation.lua` from `init.lua` (conversation state, message
  building, system prompt, context window truncation)
- [x] Extract `stream.lua` from `init.lua` (stream orchestration, cancellation)
- [x] Test infrastructure: custom harness, `minimal_init.lua`, Makefile,
  first 6 test files (tokens, context parsing, config, slash commands, costs,
  conversation)
- [x] Buffer lifecycle autocommands (`WinClosed`, `BufWipeout` for chat/input)
- [x] `:checkhealth ai-chat` integration (neovim version, curl, provider
  reachability, treesitter markdown, history/log directory writable)

**Features:**

- [x] Anthropic provider (direct API)
- [x] OpenAI-compatible provider
- [x] Context window management with oldest-first truncation
  - Per-provider default context window (Ollama 4K, Claude 200K, GPT-4o 128K)
  - Winbar shows `msgs: N (ctx: M)` when messages are truncated
  - One-time `vim.notify` when truncation first kicks in
- [x] First-run Ollama detection (async check on first send, once per session)
- [x] ~~Diff-based code application (`ga` → opens diff split)~~ *done in v0.1*
- [x] ~~Conversation persistence (save/load as JSON)~~ *done in v0.1*
- [x] ~~`/save`, `/load`, `/new` commands~~ *done in v0.1*
- [x] ~~`@diagnostics` context (LSP diagnostics)~~ *done in v0.1*
- [x] ~~`@diff` context (git diff)~~ *done in v0.1*
- [x] Thinking mode toggle (`/thinking on|off`)
- [x] ~~Cost tracking and display in winbar~~ *done in v0.1*
- [ ] `:AiChatCosts` — daily/monthly cost aggregation (session-level done in v0.1)
- [x] ~~Message navigation (`]]`, `[[`)~~ *done in v0.1*
- [x] ~~Code block navigation (`]c`, `[c`)~~ *done in v0.1*
- [x] ~~Quick actions: `<leader>ae` (explain), `<leader>af` (fix)~~ *done in v0.1*
- [x] Auto-retry on rate limits with exponential backoff
- [x] ~~Audit log (`:AiChatLog`)~~ *done in v0.1*
- [x] ~~Treesitter language injection for code blocks~~ *done in v0.1*
- [x] ~~Bold/italic markdown concealment~~ *done in v0.1*

**Also completed (not originally in v0.2 scope):**

- [x] Graceful failure for stub providers (Bedrock errors via callback, not `error()`)
- [x] `@diff` context timeout (5s bounded wait, was unbounded synchronous)
- [x] Conversation module with context window truncation budgets per provider

### Success Criteria

A user with an Anthropic API key can:
1. Have a multi-turn conversation with Claude
2. Apply a code suggestion via diff review
3. See exactly what the conversation costs
4. Resume a previous conversation after restarting neovim

---

## v0.3 — Hardening & Integration (Target: 4 weeks after v0.2)

v0.3 is split into two phases: **hardening** (structural improvements
identified during code review) and **integration** (new features). Hardening
ships first — it reduces tech debt and unlocks faster iteration.

### Phase 1: Hardening (Week 1-2) — COMPLETE

**Structural extractions:**

- [x] Extract `_setup_keymaps()` from `init.lua` into `keymaps.lua` (73 lines,
  clean `setup(keys)` API)
- [x] Extract `_setup_highlights()` from `init.lua` into `highlights.lua`
  (24 lines, idempotent `setup()`)
- [x] Move `_check_ollama()` into `providers/ollama.lua` as
  `check_reachable(provider_config)` (where it belongs)
- [x] Extract buffer lifecycle autocommands into `lifecycle.lua` (92 lines —
  not in original roadmap but necessary for line target. Takes `ui_state`
  reference and `get_stream` function, no circular deps.)
- [x] Reduce `init.lua` from 715 → 512 lines (28% reduction). The ~400 line
  target was set before v0.2 added lifecycle autocmds. Remaining bulk is
  `send()` (~100 lines of core coordination), `show_keys()` (~40 lines),
  and model/provider pickers (~50 lines each) — all legitimate coordinator
  work.
- [x] Remove duplicate streaming guard — removed `is_active()` check from
  `init.lua:send()`. `stream.lua:send()` is the single authority.

**Config ownership refactor:**

- [x] Resolve `config.get()` circular dependency — `config.lua` owns the
  resolved state via `local resolved`. `init.lua` calls
  `config.resolve(user_opts)` during `setup()`. Other modules call
  `config.get()` directly. Removed `init.lua._get_config()`.
- [x] Added `config.set(path, value)` for runtime mutations (e.g., thinking
  toggle). Dot-separated path traversal keeps config ownership clean.

**Code buffer tracking:**

- [x] Add `state.last_code_bufnr` — updated on `BufEnter` for non-special,
  named buffers. Exposed via `M.get_last_code_bufnr()`.

**Code block navigation key change:**

- [x] Change code block navigation from `]c`/`[c` to `]b`/`[b` in
  `config.lua` defaults. Help file (`doc/ai-chat.txt`) and design docs
  (UX.md, API.md, DESIGN.md) already reflected the target state.

**Tooling:**

- [x] Add `.stylua.toml` at project root (120 col width, 4-space indent,
  Unix line endings). Add `make lint` (`stylua --check lua/ tests/`) and
  `make format` to Makefile.
- [x] `.deps/` already in `.gitignore` (done in v0.2).
- [x] Add README.md — installation, setup, usage, keybindings, providers,
  config reference.

**CI (moved forward from v1.0):**

- [x] Set up GitHub Actions CI (`.github/workflows/ci.yml`) — neovim stable
  + nightly matrix. Runs `make test` and `stylua --check` on push and PR.

**New tests:**

- [x] Command router test (`tests/commands/router_spec.lua`) — parsing,
  unknown commands, malformed input (`/`, `/ `).
- [x] History store test (`tests/history/store_spec.lua`) — JSON round-trip,
  list ordering, metadata-only listing, pruning, delete, corrupt file
  handling, empty file. Uses temp directory for isolation.
- [x] Provider integration tests (`tests/providers/mock_http_spec.lua`) —
  mocks `vim.system`. Tests: NDJSON chunk accumulation, Ollama error
  response, network failure (retryable), cancel kills process, reachability
  check.

### Phase 2: Features (Week 3-4)

**Providers:**

- [x] Amazon Bedrock provider

**Context improvements:**

- [x] Context collection feedback — when `@buffer` or `@selection` is resolved,
  show a brief `vim.notify` confirming what was collected:
  `"@buffer: main.lua (142 lines, ~2,847 tokens)"`. Closes the transparency
  gap between typing the tag and seeing the result.
- [ ] Multi-file context selection
- [x] Project-local config (`.ai-chat.lua` in project root)
- [x] System prompt customization (global and per-project)

**Commands:**

- [x] Slash commands: `/explain`, `/fix`, `/test`, `/review`
- [x] Slash command completion (completion menu as you type `/`)
- [x] `/thinking show|hide` — runtime toggle for thinking block visibility
  without restarting. Adds a winbar click target or command-based toggle.

### Success Criteria

A user can:
1. Use `/review` to review a git diff before committing
2. Use Bedrock for enterprise Claude deployments
3. See what context was collected via feedback notifications
4. Include specific files as context without opening them
5. Customize the system prompt per project

---

## v0.4 — Proposal Queue: Agent-Initiated Changes (Target: 3 weeks after v0.3)

The proposal queue enables the AI to *propose* code changes that the user
reviews and applies at their own pace. This is the foundation for agentic
workflows while preserving the user-consent model. See `DESIGN.md` for the
full design rationale.

### Scope

- [ ] Proposal data model (`proposals/init.lua`)
  - Proposal struct: id, file, description, original/proposed lines, range,
    status (pending/accepted/rejected/expired), conversation reference
  - Ephemeral state — proposals live for the session, not persisted to disk
- [ ] Sign + virtual text placement for pending proposals
  - `AiChatProposalSign` sign in gutter on first line of affected range
  - Right-aligned virtual text: `"ai-chat: N pending change(s)"` in `AiChatMeta`
  - No buffer modification — undo tree is untouched
- [ ] Quickfix list integration for multi-file proposal navigation
  - Populate via `vim.fn.setqflist()` with AI intent descriptions
  - Standard `:cnext`/`:cprev`/`]q`/`[q` navigation
- [ ] Buffer attachment for conflict detection
  - Track proposal target range via `nvim_buf_attach` `on_lines` callback
  - Auto-expire proposals when user edits overlap the target range
  - Dimmed sign variant + `"ai-chat: proposal outdated"` for expired proposals
- [ ] Proposal review via existing diff split (`ui/diff.lua`)
  - `gp` on a proposal sign opens the same diff view used for chat code blocks
  - Source is the proposal queue instead of `render.get_code_block_at_cursor()`
- [ ] Proposal keymaps
  - `<leader>ar` — open proposal quickfix list
  - `<leader>an` — jump to next pending proposal (across files)
  - `gp` — preview/diff proposal at cursor (in code buffers with pending sign)
  - `ga` — accept proposal at cursor (in code buffers with pending sign)
  - `gx` — reject/dismiss proposal at cursor
  - `<leader>aR` — accept all pending proposals (with `vim.fn.confirm` prompt)
- [ ] Autocommand for deferred sign placement (files not yet open)
  - Register `BufRead` autocmd for proposal target paths
  - Place signs when the file is eventually opened
- [ ] User events: `AiChatProposalCreated`, `AiChatProposalAccepted`,
  `AiChatProposalRejected`, `AiChatProposalExpired`
- [ ] Highlight groups: `AiChatProposalSign`, `AiChatProposalExpired`
- [ ] Single `vim.notify` on proposal arrival — no modal dialogs, no focus stealing

### Success Criteria

A user can:
1. Receive AI-proposed code changes without any buffer being modified
2. See pending changes at a glance via gutter signs and virtual text
3. Navigate proposals across multiple files via the quickfix list
4. Review each proposal in a familiar diff split, applying or rejecting hunks
5. Accept or reject proposals individually, or accept all with confirmation
6. Undo an accepted proposal as a single `u` operation
7. Continue editing without interruption — expired proposals are silently marked

### Estimated Scope

~400-500 lines of new code. No new dependencies. No new UI paradigms. Every
interaction maps to something neovim users already know (signs, quickfix, diff).

---

## v0.5 — Inline Annotations: AI-Guided Code Comprehension (Target: 3 weeks after v0.4)

Inline annotations let the AI place explanatory notes directly on lines of
code, collapsing the distance between explanation and source. This builds on
the v0.4 overlay infrastructure (signs, extmarks, buffer-local keymaps) for a
non-actionable, learning-focused use case. See `DESIGN.md` for the design
rationale.

### Scope

- [ ] Extract shared overlay utilities from `ui/proposals.lua` into `ui/overlays.lua`
  - Sign placement, virtual text, namespace management, cleanup, `BufRead` deferral
  - Both proposals and annotations depend on this shared layer
- [ ] Annotation data model (`annotations/init.lua`)
  - Annotation struct: id, file, line, summary, detail, expanded (bool),
    conversation reference
  - Simpler than proposals — no original/proposed lines, no conflict detection,
    no accept/reject lifecycle
  - Ephemeral state — annotations live for the session, not persisted to disk
- [ ] `/annotate` slash command
  - `/annotate @buffer <prompt>` — annotate current buffer
  - `/annotate @selection <prompt>` — annotate visual selection
  - `/annotate @file:path <prompt>` — annotate a specific file
  - `/annotate clear` — remove all annotations from current buffer
  - `/annotate clear all` — remove all annotations from all buffers
  - Full AI response shown in chat buffer (transparency); structured annotations
    parsed and placed inline
- [ ] Response parsing for structured annotation output
  - AI returns `[annotation: line N]` markers in its response
  - Plugin parses these into annotation entries with line, summary, detail
- [ ] Extmark placement with two display states
  - **Collapsed (default):** sign + right-aligned `virt_text` summary
  - **Expanded:** sign + `virt_text` + `virt_lines` below the annotated line
    with the full explanation text
  - `virt_lines` are the key differentiator from proposals — multi-line content
    rendered inline without modifying the buffer
- [ ] Annotation keymaps (buffer-local, active when annotations are present)
  - `]a` / `[a` — jump between annotations
  - `za` — toggle expand/collapse annotation at cursor
  - `gx` — dismiss individual annotation (reuses proposal dismiss key)
  - `<leader>ag` — quick action: pre-fill `/annotate @buffer ` in chat input
  - `<leader>aA` — expand/collapse all annotations in current buffer
  - `<leader>ax` — clear all annotations from current buffer
- [ ] Highlight groups: `AiChatAnnotationSign`, `AiChatAnnotationText`,
  `AiChatAnnotationDetail`
- [ ] User events: `AiChatAnnotationCreated`, `AiChatAnnotationCleared`
- [ ] Single `vim.notify` on annotation placement

### Success Criteria

A user can:
1. Open an unfamiliar file and run `/annotate @buffer Walk me through this`
2. See annotation signs in the gutter on key lines
3. Navigate between annotations with `]a`/`[a`
4. Expand any annotation with `za` to read the full inline explanation
5. Dismiss individual annotations with `gx` or clear all with `/annotate clear`
6. See the full AI response in the chat buffer alongside the inline annotations

### Estimated Scope

~400-500 lines of new code, plus ~100 lines of shared utilities extracted from
`ui/proposals.lua` into `ui/overlays.lua`. No new dependencies.

---

## v1.0 — Stable Release (Target: 4 weeks after v0.5)

Note: v1.0 target shifted from "4 weeks after v0.4" to account for v0.5.

### Scope

- [ ] All four providers stable and tested
- [ ] Comprehensive test suite (unit + integration, building on v0.2-v0.3 foundation)
- [ ] Polished vim help docs
- [ ] Export conversation to markdown file
- [ ] Performance profiling and optimization
- [ ] Public API stability guarantee
- [ ] User event hooks fully documented
- [ ] CONTRIBUTING.md — document contribution guidelines, including the "no
  feature without a removal plan" principle as a first-class rule (not buried
  in the roadmap)

### Quality Bar

- Zero known crashes
- All providers handle auth errors gracefully
- Streaming renders smoothly at 60fps equivalent
- Memory usage stable over long conversations
- Help docs cover every command and keybinding

---

## Future (post-1.0, not committed)

These are ideas, not promises. They'll be built if users ask for them.

- **Conversation branching** — fork from any message. Requires tree data
  structure for conversations, branch selection UI, and history format changes.
  Significant complexity — only justified by user demand.
- **Image support** — multimodal message handling. Requires terminal image
  protocol support (kitty/sixel), base64 encoding, provider-specific format
  changes. Scope TBD.
- **nvim-cmp / blink.cmp source** — completion source for `@context` tags.
  Only if the built-in ghost text completion proves insufficient.
- **Project-level RAG** — optional binary companion for embedding and search
- **Shared conversations** — export/import for team use
- **Custom agents** — user-defined personas with specialized system prompts
- **Extended tool use** — let the AI call neovim functions beyond proposals
  (with explicit user approval at every step). The v0.4 proposal queue is the
  foundation: any future tool use must follow the same consent model.
- **Conversation templates** — reusable prompt patterns
- **Provider-specific features** — artifacts (Claude), function calling (OpenAI)

See `DESIGN.md` § Contribution Principles for the rules governing all
development decisions.
