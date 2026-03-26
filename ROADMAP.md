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

- [ ] Anthropic provider (direct API)
- [ ] OpenAI-compatible provider
- [x] ~~Diff-based code application (`ga` → opens diff split)~~ *done in v0.1*
- [x] ~~Conversation persistence (save/load as JSON)~~ *done in v0.1*
- [x] ~~`/save`, `/load`, `/new` commands~~ *done in v0.1*
- [x] ~~`@diagnostics` context (LSP diagnostics)~~ *done in v0.1*
- [x] ~~`@diff` context (git diff)~~ *done in v0.1*
- [ ] Thinking mode toggle (`/thinking on|off`)
- [x] ~~Cost tracking and display in winbar~~ *done in v0.1*
- [ ] `:AiChatCosts` — daily/monthly cost aggregation (session-level done in v0.1)
- [x] ~~Message navigation (`]]`, `[[`)~~ *done in v0.1*
- [x] ~~Code block navigation (`]c`, `[c`)~~ *done in v0.1*
- [x] ~~Quick actions: `<leader>ae` (explain), `<leader>af` (fix)~~ *done in v0.1*
- [ ] Auto-retry on rate limits with exponential backoff
- [x] ~~Audit log (`:AiChatLog`)~~ *done in v0.1*
- [x] ~~Treesitter language injection for code blocks~~ *done in v0.1*
- [x] ~~Bold/italic markdown concealment~~ *done in v0.1*

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
- [ ] nvim-cmp / blink.cmp integration for `@context` completion
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

## v1.0 — Stable Release (Target: 4 weeks after v0.3)

### Scope

- [ ] All four providers stable and tested
- [ ] Comprehensive test suite (unit + integration)
- [ ] Polished vim help docs
- [ ] GitHub Actions CI (neovim stable + nightly)
- [ ] Conversation branching (fork from any message)
- [ ] Export conversation to markdown file
- [ ] Image support for multimodal models
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

- **Project-level RAG** — optional binary companion for embedding and search
- **Shared conversations** — export/import for team use
- **Custom agents** — user-defined personas with specialized system prompts
- **Tool use** — let the AI call neovim functions (with explicit user approval)
- **Voice input** — speech-to-text for hands-free queries
- **Conversation templates** — reusable prompt patterns
- **Provider-specific features** — artifacts (Claude), function calling (OpenAI)

---

## Principles for Roadmap Management

1. **Each version must be usable on its own.** No "foundation" releases that
   deliver zero user value.
2. **Cut scope, not quality.** If a version is running late, remove features.
   Don't ship broken ones.
3. **User feedback drives priority.** After v0.1, the roadmap should be
   influenced by what people actually use and request.
4. **No feature without a removal plan.** Every feature should be possible to
   disable or remove without breaking the plugin.
