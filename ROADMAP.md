# ai-chat.nvim — Roadmap

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
- [x] Test infrastructure: plenary.nvim runner, `minimal_init.lua`, Makefile,
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

## v0.3 — Integration & Power Features (Target: 3 weeks after v0.2)

### Scope

- [ ] Amazon Bedrock provider
- [ ] Telescope integration (history browser, model picker)
- [ ] Slash commands: `/explain`, `/fix`, `/test`, `/review`
- [ ] Slash command completion (ghost text as you type `/`)
- [x] ~~`@file:path` context (arbitrary file inclusion)~~ *done in v0.1*
- [ ] Multi-file context selection
- [x] ~~`gO` — open code block in new split buffer~~ *done in v0.1*
- [x] ~~Input history recall (`<Up>`/`<Down>`)~~ *done in v0.1*
- [x] ~~`:AiChatConfig` — show resolved config~~ *done in v0.1*
- [x] ~~`:AiChatKeys` — show keybinding reference~~ *done in v0.1*
- [ ] Project-local config (`.ai-chat.lua` in project root)
- [ ] System prompt customization (global and per-project)

### Success Criteria

A user can:
1. Use `/review` to review a git diff before committing
2. Browse and search conversation history with Telescope
3. Include specific files as context without opening them
4. Customize the system prompt per project

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
- [ ] Comprehensive test suite (unit + integration, building on v0.2 foundation)
- [ ] Polished vim help docs
- [ ] GitHub Actions CI (neovim stable + nightly)
- [ ] Export conversation to markdown file
- [ ] Performance profiling and optimization
- [ ] Public API stability guarantee
- [ ] User event hooks fully documented

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

1. **Each version must be usable on its own.** No "foundation" releases that
   deliver zero user value.
2. **Cut scope, not quality.** If a version is running late, remove features.
   Don't ship broken ones.
3. **User feedback drives priority.** After v0.1, the roadmap should be
   influenced by what people actually use and request.
4. **No feature without a removal plan.** Every feature should be possible to
   disable or remove without breaking the plugin.
