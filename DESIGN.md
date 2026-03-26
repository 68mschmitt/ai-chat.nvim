# ai-chat.nvim — Design Document

> A transparent, native-feeling AI chat interface for neovim that treats the
> AI as a knowledgeable colleague — not a magic autocomplete that does your
> thinking for you.

## Design Philosophy

1. **Transparency over magic.** The user always knows what context the AI sees,
   what it costs, and how to override any suggestion.
2. **Native over ported.** Every interaction should feel like neovim, not a
   browser pretending to be a terminal. Buffers, splits, motions, operators.
3. **Minimal over maximal.** Ship the smallest useful thing first. Every feature
   must justify its complexity budget.
4. **Local-first.** Default to Ollama (local, free, private). Cloud providers
   are opt-in, never assumed.
5. **Composable over monolithic.** Integrate with the neovim ecosystem
   (treesitter, telescope, LSP) but never depend on it. Degrade gracefully.

## Core Decisions

### Pure Lua — No External Binary

The plugin is written entirely in Lua. No Rust sidecars, no Go binaries, no
build steps.

**Rationale:**
- `vim.system()` provides async process spawning with streaming via callbacks
- `vim.loop` (libuv) gives async I/O, timers, and process management
- Token counting can be approximated in Lua (word count × 0.75)
- The plugin installs with a single line in lazy.nvim and works immediately
- No platform-specific binaries, no `:AiChatBuild` step

**Zero dependencies.** HTTP is handled by `vim.system()` calling `curl` directly
with streaming stdout callbacks. No plenary, no external Lua libraries.

### Vertical Split — Not Floating Windows

The primary UI is a vertical split on the right side of the editor. Not a
floating window, not a tab.

**Rationale:**
- Persistent: visible alongside code, doesn't block the editor
- Navigable: standard window commands (`<C-w>h`, `<C-w>l`) work naturally
- Resizable: `<C-w><` and `<C-w>>` adjust width
- Familiar: same paradigm as file explorers, terminals, help windows
- A floating window steals focus and can't be used alongside code

The split width defaults to 25% of the editor width (minimum 60 columns).

### Provider Priority

Supported providers, in order of priority:

| Priority | Provider | Rationale |
|----------|----------|-----------|
| 1 | Ollama | Local, free, private, zero-config |
| 2 | Anthropic | Direct Claude access |
| 3 | Amazon Bedrock | Enterprise Claude deployments |
| 4 | OpenAI-compatible | Covers OpenAI, Azure, Groq, Together, LM Studio |

Default provider is **Ollama** — the only provider that requires zero
configuration, costs nothing, and sends no data anywhere.

### Conversation Model

- **Multi-turn by default.** Messages accumulate in a conversation.
- **Persistent across restarts.** Conversations are saved to
  `vim.fn.stdpath("data") .. "/ai-chat/history/"` as JSON.
- **One active conversation per neovim instance.** No tabs, no multiplexing.
  Use `/clear` or `/save` to manage conversations.
- **Context is explicit.** Every message shows what context was attached.
  No hidden system prompts beyond a minimal instruction prefix.

### Code Application Model

When the AI suggests code, the user can apply it via a diff-based workflow:

1. Cursor on a code block in the chat → press `ga` ("go apply")
2. A vertical diff split opens: left = original file, right = suggested change
3. User reviews with standard diff navigation (`]c`, `[c`, `do`, `dp`)
4. Accept with `:diffoff | only` or reject by closing the diff buffer

This reuses neovim's built-in diff mode. No custom diff rendering, no
reinventing the wheel.

## What This Plugin Is Not

- **Not an inline completion engine.** Use copilot.lua or cmp-ai for that.
  This plugin is a chat interface. The two can coexist.
- **Not a VS Code extension.** No webviews, no custom renderers, no
  electron-style panels.
- **Not a RAG engine.** No local embedding, no vector databases. If you need
  project-wide context, you send files explicitly.
- **Not an agent framework.** The AI responds to messages. It doesn't run
  shell commands, modify files autonomously, or "think in loops."

## Key References

- See `ARCHITECTURE.md` for module structure and data flow
- See `UX.md` for UI layout, keybindings, and display format
- See `API.md` for provider interfaces and plugin API
- See `ROADMAP.md` for MVP definition and version plan
