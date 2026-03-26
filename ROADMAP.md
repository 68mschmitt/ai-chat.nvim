# ai-chat.nvim — Roadmap

## v0.1 — MVP (Target: 2 weeks)

Ship the smallest useful thing. Get it in people's hands.

### Scope

- [ ] Toggle chat split (right side vertical split)
- [ ] Input area with submit on `<CR>`
- [ ] Send message, receive streamed response
- [ ] One provider: Ollama (easiest to test, no API key)
- [ ] `@buffer` context (send current buffer content)
- [ ] `@selection` context (send visual selection)
- [ ] Code block detection in chat buffer
- [ ] `gY` — yank code block under cursor
- [ ] Basic markdown rendering:
  - Headers rendered with highlight groups
  - Code blocks with treesitter syntax highlighting (language injection)
  - Bold text with concealed delimiters
- [ ] Token usage display in message metadata
- [ ] Cancel generation with `<C-c>`
- [ ] `/clear` — clear conversation
- [ ] `/model` — switch model via `vim.ui.select`
- [ ] `/help` — list commands
- [ ] Winbar with provider, model, message count
- [ ] Error display inline in chat buffer
- [ ] `setup()` with configuration validation
- [ ] Vim help file (`:help ai-chat`)

### Non-Goals for v0.1

- No persistence / history
- No diff-based code application
- No cloud providers
- No telescope integration
- No cost tracking
- No slash command completion
- No thinking mode

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
- [ ] Diff-based code application (`ga` → opens diff split)
- [ ] Conversation persistence (save/load as JSON)
- [ ] `/save`, `/load`, `/new` commands
- [ ] `@diagnostics` context (LSP diagnostics)
- [ ] `@diff` context (git diff)
- [ ] Thinking mode toggle (`/thinking on|off`)
- [ ] Cost tracking and display in winbar
- [ ] `:AiChatCosts` — session/daily/monthly summary
- [ ] Message navigation (`]]`, `[[`)
- [ ] Code block navigation (`]c`, `[c`)
- [ ] Quick actions: `<leader>ae` (explain), `<leader>af` (fix)
- [ ] Auto-retry on rate limits with exponential backoff
- [ ] Audit log (`:AiChatLog`)

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
- [ ] `@file:path` context (arbitrary file inclusion)
- [ ] Multi-file context selection
- [ ] `gO` — open code block in new split buffer
- [ ] Input history recall (`<Up>`/`<Down>`)
- [ ] `:AiChatConfig` — show resolved config
- [ ] `:AiChatKeys` — show keybinding reference
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
