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

## Proposals (Agent-Initiated Changes)

When the AI proposes code changes, the user is notified passively and reviews
at their own pace. The buffer is never modified without explicit consent.

### Visual Indicators

Pending proposals are shown via sign column and virtual text on the target
line range:

```
  42 │ ◆ local function setup(opts)          ai-chat: 1 pending change
  43 │   if opts == nil then
  44 │     return
  45 │   end
```

- **Sign:** `AiChatProposalSign` (◆) in the gutter on the first affected line,
  placed via `nvim_buf_set_extmark` with `sign_text`
- **Virtual text:** Right-aligned hint using `virt_text` in `AiChatMeta`
  highlight. Visually consistent with existing metadata display.
- **Expired proposals:** When the user edits within a proposal's target range,
  the sign changes to a dimmed `AiChatProposalExpired` variant and the virtual
  text updates to `"ai-chat: proposal outdated"`.

### Notification Flow

When proposals arrive from the AI:

1. Signs and virtual text are placed on buffers already loaded
2. For files not yet open, a `BufRead` autocommand defers sign placement
3. The quickfix list is updated with all pending proposals
4. A single `vim.notify` is emitted:
   `[ai-chat] 3 code changes proposed — <leader>ar to review`

No modal dialogs, no floating windows, no focus stealing. One line of
notification. The user finishes their thought, reviews when ready.

### Quickfix Integration

Pending proposals populate a standard quickfix list:

```
ai-chat pending changes (3 items):
  src/config.lua:42         | Add nil guard for opts parameter
  src/providers/init.lua:15 | Fix provider lookup for missing key
  tests/config_spec.lua:1   | [new file] Test for nil guard
```

Standard navigation applies: `:copen`, `:cnext`, `:cprev`, `]q`/`[q`. The
quickfix entry text shows the AI's one-line description of intent — the user
sees *why* before *what*.

For new files the AI wants to create, the quickfix entry shows `[new file]`
and `gp` opens a scratch buffer with the proposed content. `ga` writes it to
disk. `gx` dismisses it.

### Proposal Highlight Groups

```lua
AiChatProposalSign    = { link = "DiagnosticSignHint" }
AiChatProposalExpired = { link = "DiagnosticSignWarn" }
```

## Annotations (AI-Guided Code Comprehension)

Annotations place AI explanations directly on lines of code. Unlike proposals,
annotations are informational — there's nothing to accept or reject. The buffer
is never modified. The goal is to collapse the distance between explanation and
source, so the user doesn't have to cross-reference the chat buffer with their
code.

### Invocation

```
/annotate @buffer Walk me through this file — what are the key patterns?
/annotate @selection What's happening in this block?
/annotate @buffer @file:src/types.lua How do these two files relate?
/annotate clear
/annotate clear all
```

Or via quick action: `<leader>ag` pre-fills `/annotate @buffer ` in the chat
input with the cursor at the end.

The AI response appears in the chat buffer as normal (transparency). Structured
annotation markers in the response are parsed and placed as inline extmarks.

### Visual States

**Collapsed (default):** sign + short right-aligned virtual text.

```
  12 │ 📝 local M = {}                              ai-chat: module pattern
  ...
  34 │ 📝 local function on_chunk(text)              ai-chat: vim.schedule required
  ...
  67 │ 📝   ["Content-Type"] = "application/x-ndjson"  ai-chat: streaming format
```

**Expanded (toggle with `za`):** sign + virtual text + `virt_lines` below.

```
  34 │ 📝 local function on_chunk(text)              ai-chat: vim.schedule required
     │   ╰─ This is the streaming callback. It runs outside neovim's main
     │      loop (called from vim.system's stdout handler), so every buffer
     │      mutation inside MUST be wrapped in vim.schedule(). Missing this
     │      causes segfaults.
  35 │     vim.schedule(function()
```

`virt_lines` insert visible text below the annotated line without modifying the
buffer. They don't affect line numbers, don't show up in `wc -l`, and don't
pollute the undo tree.

### Why Not `vim.diagnostic`?

Annotations use `nvim_buf_set_extmark` directly in a dedicated namespace — not
`vim.diagnostic`. Diagnostics are designed for problems (errors, warnings) and
share namespace with real LSP output. Pushing AI annotations through
`vim.diagnostic` would intermingle explanations with actual type errors, making
it impossible to tell "this is a real problem" from "this is the AI explaining
something." That's a transparency violation. Raw extmarks in a separate
namespace give us the same visual pattern without the ecosystem pollution.

### Annotation Highlight Groups

```lua
AiChatAnnotationSign   = { link = "DiagnosticSignInfo" }
AiChatAnnotationText   = { link = "Comment" }
AiChatAnnotationDetail = { link = "Comment" }
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

**Context collection feedback:** On resolution, a brief `vim.notify` confirms
what was collected before the message is sent:

```
@buffer: main.lua (142 lines, ~2,847 tokens)
```

This provides immediate feedback that the correct file was targeted and how
much of the context budget was consumed. If the buffer was empty or the
selection was nil, the notification makes that visible immediately — not after
the AI responds with a confused answer.

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
| `<leader>ar` | n | Open proposal quickfix list |
| `<leader>an` | n | Jump to next pending proposal (across files) |
| `<leader>aR` | n | Accept all pending proposals (with confirmation) |
| `<leader>ag` | n | Quick annotate: pre-fill `/annotate @buffer ` in chat input |
| `<leader>aA` | n | Expand/collapse all annotations in current buffer |
| `<leader>ax` | n | Clear all annotations from current buffer |

### Chat Buffer Keybindings (buffer-local, active in chat buffer)

| Binding | Mode | Action |
|---------|------|--------|
| `q` | n | Close chat panel |
| `<C-c>` | n, i | Cancel active generation |
| `]]` | n | Jump to next message |
| `[[` | n | Jump to previous message |
| `]b` | n | Jump to next code block |
| `[b` | n | Jump to previous code block |
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

### Code Buffer Keybindings (buffer-local, active in buffers with pending proposals)

| Binding | Mode | Action |
|---------|------|--------|
| `gp` | n | Review proposal at cursor (opens diff) |
| `ga` | n | Review proposal at cursor (opens diff) |
| `gx` | n | Reject/dismiss proposal at cursor |

These keymaps are only set on buffers that have pending proposals. They
override neovim's built-in `gp` (put linewise) only in buffers with active
proposal signs.

`ga` and `gp` are identical in code buffers — both open the diff split for
review. There is no direct-apply path from the code buffer. This ensures the
user always sees the proposed change before it takes effect, consistent with
the plugin's transparency principle.

Inside the diff view, `ga` on the suggested buffer accepts all changes and
closes the diff. For hunk-level control, use `do`/`dp` to cherry-pick and
`:diffoff | only` to finish.

`ga` is intentionally the universal "review AI suggestion" key. In the chat
buffer it opens a diff for a code block. In a code buffer with a proposal it
opens a diff for the proposal. Inside the diff view it accepts all changes.
Same key, consistent intent, escalating commitment.

`gx` dismisses the proposal and clears its sign. When both proposals and
annotations are present on the same buffer, `gx` targets proposals first
(actionable items take priority). If no proposal exists on the cursor line, it
falls through to dismiss annotations. When both exist on the same line,
dismissing a proposal shows a brief `vim.notify` confirming which layer was
targeted.

### Code Buffer Keybindings (buffer-local, active in buffers with annotations)

| Binding | Mode | Action |
|---------|------|--------|
| `]a` | n | Jump to next annotation |
| `[a` | n | Jump to previous annotation |
| `za` | n | Toggle expand/collapse annotation at cursor |
| `gx` | n | Dismiss annotation at cursor |

These keymaps are only set on buffers that have annotations. `]a`/`[a` follows
the standard `]x`/`[x` navigation convention (`]d` for diagnostics, `]b` for
code blocks in chat, `]q` for quickfix). `za` echoes neovim's fold toggle. `gx` is
shared with proposals — when both exist on a buffer, proposals take priority
on the cursor line (see proposal keybindings above).

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
| `/annotate [@ctx] [prompt]` | Place inline annotations on buffer/selection |
| `/thinking [on\|off\|show\|hide]` | Toggle extended thinking mode (`on`/`off`) or toggle thinking block visibility (`show`/`hide`) without restarting |
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
- **Thinking mode:** On/off indicator (always shown for providers that support
  it — showing `thinking: off` when disabled makes the state visible at all
  times, not just when enabled)
- **Message count:** Number of messages in current conversation. When context
  window truncation is active, shows `msgs: 24 (ctx: 12)` — total messages
  and how many fit in the context window.
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
