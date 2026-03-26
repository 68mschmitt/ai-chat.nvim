# ai-chat.nvim — Architecture

## Directory Structure

```
ai-chat.nvim/
├── plugin/
│   └── ai-chat.lua              # Lazy-loaded entry point (commands, autocommands)
├── lua/
│   └── ai-chat/
│       ├── init.lua              # setup(), public API, module coordinator
│       ├── config.lua            # Configuration schema, defaults, validation
│       ├── providers/
│       │   ├── init.lua          # Provider registry and dispatcher
│       │   ├── ollama.lua        # Ollama provider
│       │   ├── anthropic.lua     # Anthropic API provider
│       │   ├── bedrock.lua       # AWS Bedrock provider
│       │   └── openai_compat.lua # OpenAI-compatible provider
│       ├── ui/
│       │   ├── init.lua          # UI coordinator
│       │   ├── chat.lua          # Chat split window management
│       │   ├── input.lua         # Input area (prompt buffer)
│       │   ├── render.lua        # Message rendering (markdown, code blocks)
│       │   ├── diff.lua          # Diff-based code application
│       │   └── spinner.lua       # Streaming progress indicator
│       ├── context/
│       │   ├── init.lua          # Context coordinator
│       │   ├── buffer.lua        # @buffer context collector
│       │   ├── selection.lua     # @selection context collector
│       │   ├── diagnostics.lua   # @diagnostics context collector (LSP)
│       │   ├── diff.lua          # @diff context collector (git)
│       │   └── file.lua          # @file context collector
│       ├── commands/
│       │   ├── init.lua          # Command router
│       │   └── slash.lua         # Slash command definitions (/clear, /model, etc.)
│       ├── history/
│       │   ├── init.lua          # Conversation persistence
│       │   └── store.lua         # File-based JSON storage
│       └── util/
│           ├── tokens.lua        # Approximate token counting
│           ├── costs.lua         # Cost estimation per provider/model
│           ├── log.lua           # Audit logging
│           └── ui.lua            # Shared UI helpers (scratch splits)
├── doc/
│   └── ai-chat.txt              # Vim help file
└── tests/
    ├── minimal_init.lua          # Minimal config for test runner
    ├── providers/
    │   └── ollama_spec.lua
    ├── ui/
    │   └── chat_spec.lua
    └── context/
        └── buffer_spec.lua
```

## Module Dependency Graph

```
plugin/ai-chat.lua
    └── ai-chat.init
            ├── ai-chat.config         (configuration)
            ├── ai-chat.providers.init (provider dispatch)
            │       ├── .ollama
            │       ├── .anthropic
            │       ├── .bedrock
            │       └── .openai_compat
            ├── ai-chat.ui.init        (UI coordination)
            │       ├── .chat           (split management)
            │       ├── .input          (prompt buffer)
            │       ├── .render         (message display)
            │       ├── .diff           (code application)
            │       └── .spinner        (progress)
            ├── ai-chat.context.init   (context collection)
            │       ├── .buffer
            │       ├── .selection
            │       ├── .diagnostics
            │       ├── .diff
            │       └── .file
            ├── ai-chat.commands.init  (command routing)
            │       └── .slash
            ├── ai-chat.history.init   (persistence)
            │       └── .store
            └── ai-chat.util.*        (shared utilities)
```

**Rule:** Arrows point downward only. `ui` never calls `providers` directly —
it goes through `init` (the coordinator). `providers` never touch `ui`.
`context` is a pure data layer with no side effects.

## Data Flow

### Sending a Message

```
User types message in input buffer
    │
    ▼
input.lua: on_submit()
    │
    ├── Parse for slash commands → commands/slash.lua
    │   (if /command detected, route there, stop)
    │
    ├── Collect context references (@buffer, @selection, etc.)
    │   → context/init.lua → context/*.lua
    │   Returns: { type, content, token_estimate, display_label }
    │
    ├── Build message payload
    │   {
    │     role = "user",
    │     content = user_text,
    │     context = { collected_context },
    │   }
    │
    ├── Append to conversation history
    │   → history/init.lua
    │
    ├── Render user message in chat buffer
    │   → ui/render.lua
    │
    ▼
init.lua: send()
    │
    ├── Build provider messages array
    │   (system prompt + conversation history + context)
    │
    ├── Start spinner
    │   → ui/spinner.lua
    │
    ▼
providers/init.lua: chat(messages, opts, callbacks)
    │
    ├── Select active provider
    ├── Call provider.chat(messages, opts, on_chunk, on_done, on_error)
    │
    ▼
provider (e.g., ollama.lua):
    │
    ├── Build HTTP request
    ├── Send via vim.system() with streaming
    ├── For each chunk:
    │       on_chunk(text)
    │           → vim.schedule() → ui/render.lua: append_chunk()
    │
    ├── On completion:
    │       on_done(full_text, usage)
    │           → vim.schedule()
    │           → ui/render.lua: finalize_response(usage)
    │           → ui/spinner.lua: stop()
    │           → history/init.lua: save()
    │           → util/costs.lua: record(usage)
    │
    └── On error:
            on_error(err)
                → vim.schedule()
                → ui/render.lua: show_error(err)
                → ui/spinner.lua: stop()
```

### Applying a Code Suggestion

```
User presses `ga` on a code block in chat buffer
    │
    ▼
ui/render.lua: get_code_block_at_cursor()
    │
    ├── Uses treesitter or regex to find code block boundaries
    ├── Extracts: { language, content, source_file?, line_range? }
    │
    ▼
ui/diff.lua: apply(code_block)
    │
    ├── Determine target file:
    │   1. From context metadata (if @buffer or @selection was used)
    │   2. From code block fence info (```lua path/to/file.lua)
    │   3. Prompt user via vim.ui.select if ambiguous
    │
    ├── Create temp buffer with suggested content
    ├── Open vertical diff split: original | suggested
    ├── Set diff mode on both buffers
    │
    ▼
User reviews diff with standard neovim diff commands:
    ]c / [c  — navigate hunks
    do / dp  — obtain / put changes
    :diffoff | only — accept and close
    :q       — reject and close
```

## Streaming Architecture

Streaming is the critical path for UX. Here is the detailed flow:

```lua
-- Provider sends chunks via callback
local function on_chunk(text)
    -- IMPORTANT: This callback runs outside neovim's main loop
    -- (called from vim.system's stdout callback)
    -- All nvim_buf_* calls MUST be scheduled

    vim.schedule(function()
        -- Accumulate text in a line buffer
        line_buffer = line_buffer .. text

        -- Split on newlines
        local lines = vim.split(line_buffer, "\n", { plain = true })

        -- Write all complete lines to the buffer
        for i = 1, #lines - 1 do
            vim.api.nvim_buf_set_lines(bufnr, write_line, write_line, false, { lines[i] })
            write_line = write_line + 1
        end

        -- Keep the incomplete trailing fragment
        line_buffer = lines[#lines]

        -- Update the current incomplete line (overwrite in place)
        if line_buffer ~= "" then
            vim.api.nvim_buf_set_lines(bufnr, write_line, write_line + 1, false, { line_buffer })
        end

        -- Auto-scroll only if enabled and user hasn't scrolled up
        if config.chat.auto_scroll then
            local last = vim.api.nvim_buf_line_count(bufnr)
            local win_height = vim.api.nvim_win_get_height(win)
            local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
            if cursor_line >= last - win_height - 5 then
                vim.api.nvim_win_set_cursor(win, { last, 0 })
            end
        end
    end)
end
```

**Key rules:**
- `vim.schedule()` wraps every buffer mutation. No exceptions.
- Line-buffer accumulation prevents character-by-character jitter.
- Auto-scroll respects `config.chat.auto_scroll` and user scroll position.
- Buffer is set `nomodifiable` except during scheduled writes.
- A `vim.loop.new_timer()` drives the spinner animation independently.

## State Management

The plugin maintains minimal global state:

```lua
-- ai-chat/init.lua (module-level state)
local state = {
    config = {},              -- resolved configuration
    conversation = {          -- active conversation
        id = "",              -- UUID
        messages = {},        -- { role, content, context, usage }
        provider = "",        -- active provider name
        model = "",           -- active model name
        created_at = 0,       -- timestamp
    },
    ui = {                    -- UI state (managed by ui/init.lua)
        chat_bufnr = nil,
        chat_winid = nil,
        input_bufnr = nil,
        input_winid = nil,
        is_open = false,
    },
    streaming = {             -- active stream state
        active = false,
        cancel_fn = nil,      -- call to abort current generation
    },
}
```

State is not exposed directly. Access is through functions on the `init` module:

```lua
M.get_conversation()  -- returns conversation table (read-only copy)
M.get_config()        -- returns resolved config
M.is_streaming()      -- returns boolean
M.cancel()            -- cancels active stream
```

## Error Handling Strategy

Errors are categorized by severity and handled differently:

| Category | Example | Handling |
|----------|---------|----------|
| **Transient** | Network timeout, rate limit | Inline in chat buffer, auto-retry with backoff |
| **Config** | Bad API key, wrong endpoint | `vim.notify` at WARN, actionable message |
| **Fatal** | Plugin bug, nil reference | `vim.notify` at ERROR, log traceback |
| **Validation** | Empty message, no provider | Inline hint in input area |

All errors are logged to the audit log (`util/log.lua`) regardless of severity.

Retry policy for transient errors:
- Exponential backoff: 2s, 4s, 8s
- Maximum 3 attempts
- User can cancel with `<C-c>` or force retry with `<CR>`
- Countdown displayed inline in the chat buffer

## Testing Strategy

- Unit tests for pure logic: `context/*.lua`, `util/*.lua`, `commands/slash.lua`
- Integration tests for provider communication (mocked HTTP)
- UI tests are manual — buffer management is hard to test in isolation
- Test runner: `nvim --headless` with `minimal_init.lua` (loads only ai-chat)
- CI: GitHub Actions with neovim nightly + stable
