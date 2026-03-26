# ai-chat.nvim — UX Design

## Layout

```
┌──────────────────────────────────┬─────────────────────────────────┐
│                                  │  ai-chat │ ollama/llama3.2     │
│                                  │  thinking: off │ msgs: 4       │
│   [user's code buffer]          ├─────────────────────────────────┤
│                                  │                                 │
│                                  │  ## You          [@buffer: m..] │
│                                  │  How do I fix the type error?   │
│                                  │                                 │
│                                  │  ## Assistant     [847→1203 $..] │
│                                  │  The issue is that `opts` can   │
│                                  │  be `nil`. Here's the fix:      │
│                                  │                                 │
│                                  │  ```lua                         │
│                                  │  local function setup(opts)     │
│                                  │    opts = opts or {}            │
│                                  │  end                            │
│                                  │  ```                            │
│                                  │                                 │
│                                  ├─────────────────────────────────┤
│                                  │  > Type message... (@buf, @sel) │
│                                  │                                 │
└──────────────────────────────────┴─────────────────────────────────┘
```

### Window Anatomy

The chat panel consists of **three regions** within a single vertical split:

| Region | Implementation | Purpose |
|--------|---------------|---------|
| **Winbar** | `vim.wo.winbar` | Provider, model, thinking mode, message count |
| **Chat buffer** | Scratch buffer, `nomodifiable`, `filetype=aichat` | Conversation display |
| **Input area** | Separate scratch buffer at bottom of split | User composes messages |

The input area is a horizontal split *within* the chat split, occupying the
bottom 3-5 lines. This gives the user a dedicated, editable buffer for
composing messages while the chat history remains read-only above.

### Split Behavior

- **Width:** 25% of editor width, minimum 60 columns, maximum 120 columns
- **Position:** Right side (`:botright vsplit` semantics)
- **Persistence:** The split stays open until explicitly closed. Switching
  buffers in the code area doesn't affect it.
- **Resize:** Standard `<C-w><`, `<C-w>>`, `<C-w>=` all work

## Chat Buffer Format

The chat buffer uses a structured markdown-like format with extmarks for
metadata:

```
## You                                          [@buffer: main.lua]
How do I fix the type error on line 42?

## Assistant                    [claude-3.5-sonnet · 847→1203 · $0.009]
The issue is that `opts` can be `nil` when no arguments are passed.
Here's the fix:

```lua
local function setup(opts)
  opts = opts or {}
  -- rest of function
end
```

This works because the `or` operator returns the first truthy value.

## You                                       [@selection: main.lua:42-45]
What about this pattern instead?

## Assistant                     [claude-3.5-sonnet · 312→890 · $0.006]
⠋ streaming...
```

### Rendering Rules

1. **Message headers** (`## You`, `## Assistant`) use `AiChatUser` and
   `AiChatAssistant` highlight groups. Bold, distinct from body text.

2. **Metadata brackets** (`[@buffer: main.lua]`, `[847→1203 · $0.009]`) are
   rendered via `nvim_buf_set_extmark` with `virt_text` — right-aligned on
   the header line. Visually present but not part of yanked text.

3. **Code blocks** get treesitter language injection for syntax highlighting.
   A ` ```lua ` fence produces lua-highlighted content. This is the single
   biggest UX win.

4. **Markdown formatting:**
   - Headers (`##`) — highlighted, not concealed
   - Bold (`**text**`) — concealed delimiters, bold highlight
   - Inline code (`` `code` ``) — concealed delimiters, code highlight
   - Lists (`-`, `1.`) — rendered as-is (already readable in monospace)
   - Tables — rendered as-is (no fancy box drawing)
   - Images — not rendered (show alt text only)

5. **Separator lines** between messages use `nvim_buf_set_extmark` with
   `virt_lines` — a thin horizontal rule that doesn't occupy buffer lines.

### Highlight Groups

All highlights are defined with sensible defaults and can be overridden by
colorschemes:

```lua
-- Default highlight definitions
AiChatUser           = { link = "Title" }
AiChatAssistant      = { link = "Statement" }
AiChatMeta           = { link = "Comment" }
AiChatCodeBlock      = { link = "Normal" }
AiChatCodeBlockBg    = { bg = slightly_darker_than_Normal }
AiChatError          = { link = "DiagnosticError" }
AiChatWarning        = { link = "DiagnosticWarn" }
AiChatSpinner        = { link = "DiagnosticInfo" }
AiChatSeparator      = { link = "WinSeparator" }
AiChatInputPrompt    = { link = "Question" }
AiChatContextTag     = { link = "Tag" }
```

## Input Area

The input area is a small editable buffer at the bottom of the chat split.

### Behavior

- **Prompt indicator:** `> ` shown via `nvim_buf_set_extmark` (virtual text,
  not actual buffer content)
- **Auto-resize:** Grows from 3 lines up to 10 lines as the user types.
  Shrinks back after sending.
- **Submit:** `<CR>` in normal mode sends the message. `<S-CR>` or `<C-CR>`
  inserts a newline (for multi-line messages). In insert mode, `<CR>` inserts
  a newline normally; `<C-CR>` sends.
- **History recall:** `<Up>` in normal mode on an empty input recalls the
  previous message (like shell history).
- **Context tags:** Typing `@` triggers completion of context references
  (`@buffer`, `@selection`, `@diagnostics`, `@diff`, `@file`).

### Context References

Context references are typed inline with the message:

```
@buffer How do I fix the type error on line 42?
@selection Explain this code
@diagnostics Fix all the warnings
@diff Review my changes
@file:src/utils.lua What does this helper do?
```

When multiple references are used, they stack:

```
@buffer @diagnostics Fix the errors shown in the diagnostics
```

**Context tag display:** After sending, the resolved context is shown in the
message header metadata: `[@buffer: main.lua (142 lines, ~2,847 tokens)]`

## Keybindings

### Philosophy

All keybindings are:
- **Leader-prefixed** for global actions (toggle, send, etc.)
- **Buffer-local** for chat-specific actions (navigate, yank, apply)
- **Overridable** — every binding can be remapped in setup()
- **Documented** — `:AiChatKeys` lists all active bindings

### Global Keybindings (default leader: `<leader>a`)

| Binding | Mode | Action |
|---------|------|--------|
| `<leader>aa` | n | Toggle chat panel |
| `<leader>as` | n, v | Send selection to chat (opens panel if closed) |
| `<leader>ae` | n, v | Quick explain: sends "Explain this:" + selection |
| `<leader>af` | n, v | Quick fix: sends "Fix this:" + selection/diagnostics |
| `<leader>ac` | n | Focus chat input (opens panel if closed) |
| `<leader>am` | n | Switch model (via `vim.ui.select`) |
| `<leader>ap` | n | Switch provider (via `vim.ui.select`) |

### Chat Buffer Keybindings (buffer-local, active in chat buffer)

| Binding | Mode | Action |
|---------|------|--------|
| `q` | n | Close chat panel |
| `<C-c>` | n, i | Cancel active generation |
| `]]` | n | Jump to next message |
| `[[` | n | Jump to previous message |
| `]c` | n | Jump to next code block |
| `[c` | n | Jump to previous code block |
| `gY` | n | Yank code block under cursor to clipboard |
| `ga` | n | Apply code block under cursor (open diff) |
| `gO` | n | Open code block in a new split buffer |
| `i` | n | Focus input area (enter insert mode) |
| `?` | n | Show keybinding help |

### Input Buffer Keybindings (buffer-local, active in input area)

| Binding | Mode | Action |
|---------|------|--------|
| `<CR>` | n | Send message |
| `<C-CR>` | i | Send message |
| `<CR>` | i | Insert newline |
| `<S-CR>` | n | Insert newline |
| `<Up>` | n | Recall previous message (on empty input) |
| `<Down>` | n | Recall next message |
| `<C-c>` | n, i | Cancel active generation |
| `<Tab>` | i | Accept context tag completion |
| `q` | n | Close chat panel (when input is empty) |

## Slash Commands

Typed in the input area. Parsed on submit.

### MVP Commands

| Command | Action |
|---------|--------|
| `/clear` | Clear conversation, start fresh |
| `/new` | Save current conversation, start a new one |
| `/model [name]` | Switch model (shows picker if no name given) |
| `/provider [name]` | Switch provider (shows picker if no name given) |
| `/context` | Show current context details in chat |
| `/save [name]` | Save conversation with optional name |
| `/load` | Browse and load saved conversations |
| `/help` | List available commands |

### Extended Commands (post-MVP)

| Command | Action |
|---------|--------|
| `/explain` | Explain the current buffer or selection |
| `/fix` | Fix errors in buffer or selection |
| `/test` | Generate tests for buffer or selection |
| `/review` | Code review the current git diff |
| `/thinking [on\|off]` | Toggle extended thinking mode |
| `/system [prompt]` | Set or view the system prompt |

### Completion

When the user types `/` as the first character in the input area, show
available commands via extmark ghost text. As they type more characters, filter
the list. No external completion plugin needed — this is a simple prefix match
rendered with virtual text.

## Winbar

The winbar provides at-a-glance status:

```
 ai-chat │ ollama/llama3.2 │ thinking: off │ msgs: 12 │ $0.00
```

Components:
- **Plugin name:** Static identifier
- **Provider/model:** Active provider and model name
- **Thinking mode:** On/off indicator (only for providers that support it)
- **Message count:** Number of messages in current conversation
- **Session cost:** Cumulative cost for this session ($0.00 for local models)

When streaming, the winbar updates to show:
```
 ai-chat │ ollama/llama3.2 │ ⠋ generating... │ msgs: 12 │ $0.00
```

## Error Display

Errors appear inline in the chat buffer, replacing where the response would
have been:

```
─── Error ──────────────────────────────────────────────
  Rate limited. Retrying in 12s... (attempt 2/3)
  Press <C-c> to cancel, <CR> to retry now.
────────────────────────────────────────────────────────
```

```
─── Error ──────────────────────────────────────────────
  Ollama not running at localhost:11434.
  Start it with `ollama serve` or switch provider
  with /provider anthropic.
────────────────────────────────────────────────────────
```

Error blocks use the `AiChatError` highlight group. They are interactive:
`<CR>` retries, `<C-c>` cancels and clears the error.

## Accessibility

- All information conveyed by color is also conveyed by text/position
- No animations that can't be disabled
- Spinner can be disabled in config
- All virtual text has fallback plain text representations
- Screen reader compatible: buffer content is real text, not just extmarks
