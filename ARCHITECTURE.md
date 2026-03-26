# ai-chat.nvim — Architecture

## Directory Structure

```
ai-chat.nvim/
├── plugin/
│   └── ai-chat.lua              # Lazy-loaded entry point (commands, autocommands)
├── lua/
│   └── ai-chat/
│       ├── init.lua              # setup(), public API, module coordinator (~250 lines)
│       ├── config.lua            # Configuration schema, defaults, validation
│       ├── conversation.lua      # Conversation state, message building, system prompt
│       ├── stream.lua            # Stream orchestration, cancellation
│       ├── health.lua            # :checkhealth integration
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
│       │   ├── overlays.lua      # Shared extmark utilities (signs, virt_text, cleanup)
│       │   ├── proposals.lua     # Proposal signs, virtual text, quickfix
│       │   ├── annotations.lua   # Annotation signs, virt_text, virt_lines
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
│       ├── proposals/
│       │   └── init.lua          # Proposal data model, lifecycle, conflict detection
│       ├── annotations/
│       │   └── init.lua          # Annotation data model, parsing, lifecycle
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
    └── ai-chat.init              (coordinator, public API, ~250 lines)
            ├── ai-chat.conversation   (conversation data lifecycle)
            ├── ai-chat.stream         (stream orchestration)
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
            │       ├── .overlays       (shared extmark utilities)
            │       ├── .proposals      (proposal signs, quickfix)
            │       ├── .annotations    (annotation signs, virt_lines)
            │       └── .spinner        (progress)
            ├── ai-chat.context.init   (context collection)
            │       ├── .buffer
            │       ├── .selection
            │       ├── .diagnostics
            │       ├── .diff
            │       └── .file
            ├── ai-chat.commands.init  (command routing)
            │       └── .slash
            ├── ai-chat.proposals.init (proposal lifecycle)
            ├── ai-chat.annotations.init (annotation lifecycle)
            ├── ai-chat.history.init   (persistence)
            │       └── .store
            └── ai-chat.util.*        (shared utilities)
```

**Rule:** Arrows point downward only. `ui` never calls `providers` directly —
it goes through `init` (the coordinator). `providers` never touch `ui`.
`context` is a pure data layer with no side effects. `proposals` and
`annotations` own their data and lifecycle but never call `ui` directly —
`init` coordinates between data modules and their UI counterparts.
`ui/overlays` provides shared extmark utilities consumed by both
`ui/proposals` and `ui/annotations`. `conversation` is pure data — it never
calls `ui` or `providers`. `stream` calls `providers` and `ui` (render,
spinner) but receives conversation data as arguments and calls back to `init`
via callbacks for history/costs/winbar updates.

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
    ▼
init.lua: send()  (~30 lines of orchestration)
    │
    ├── conversation.lua: append_message(msg)
    │   (pure data — add to conversation.messages)
    │
    ├── Render user message in chat buffer
    │   → ui/render.lua
    │
    ├── conversation.lua: build_provider_messages(config)
    │   ├── system prompt + conversation history + context
    │   └── truncate_to_budget(messages, max_tokens)
    │       (oldest messages first, system prompt always preserved)
    │
    ▼
stream.lua: send(provider_messages, opts, callbacks)
    │
    ├── Start spinner → ui/spinner.lua
    │
    ├── providers/init.lua: chat(messages, opts, on_chunk, on_done, on_error)
    │   ├── Select active provider
    │   └── Call provider.chat(...)
    │
    ├── For each chunk:
    │       on_chunk(text)
    │           → vim.schedule() → ui/render.lua: append_chunk()
    │
    ├── On completion:
    │       on_done(full_text, usage)
    │           → vim.schedule()
    │           → ui/render.lua: finalize_response(usage)
    │           → ui/spinner.lua: stop()
    │           → callbacks.on_done(full_text, usage)
    │               (init.lua handles: history.save(), costs.record(), winbar)
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

### Receiving an Agent-Initiated Proposal

```
AI response parsed → proposals extracted
    │
    ▼
init.lua: handle_proposals(proposals)
    │
    ├── proposals/init.lua: add(proposal)
    │   ├── Create proposal entry:
    │   │   {
    │   │     id, file, description, original_lines, proposed_lines,
    │   │     range, status = "pending", conversation_id
    │   │   }
    │   ├── Append to state.proposals
    │   └── nvim_buf_attach() for conflict detection
    │       (on_lines callback → proposals/init.lua: expire if user edits overlap)
    │
    ├── ui/proposals.lua (called by init, not by proposals/):
    │   │
    │   ├── For each proposal:
    │   │   ├── If target buffer is loaded:
    │   │   │   ├── ui/overlays.lua: place_sign(bufnr, proposal)
    │   │   │   │   (sign column + right-aligned virtual text via extmarks)
    │   │   │   └── Set buffer-local keymaps: gp, ga, gx
    │   │   │
    │   │   └── If target buffer is NOT loaded:
    │   │       └── Register BufRead autocmd for file path
    │   │           (places signs when file is eventually opened)
    │   │
    │   └── update_quickfix()
    │       (populate quickfix list with all pending proposals)
    │
    ├── vim.notify("[ai-chat] N code changes proposed — <leader>ar to review")
    │
    └── Emit AiChatProposalCreated user event
```

### Accepting / Rejecting a Proposal

`ga` and `gp` both open the diff — there is no direct-apply path. This
ensures the user always reviews before changes are made. Quick-accept is
available *inside* the diff view via `ga` on the suggested buffer.

```
User presses `ga` or `gp` on a line with a proposal sign
    │
    ▼
proposals/init.lua: get_at_cursor(bufnr, line)
    │
    ├── Find proposal matching this buffer and line range
    │
    ▼
ui/diff.lua: apply(proposal_as_block)
    │
    ├── Same diff split as chat-based code application
    ├── Left = original file, Right = proposed content
    ├── Buffer-local `ga` on suggested buffer: accept all + close diff
    │
    ▼
User reviews with standard diff commands:
    ]c / [c  — navigate hunks
    do / dp  — cherry-pick individual hunks
    ga       — accept all changes and close (suggested buffer only)
    :diffoff | only — finish and close diff
    :q       — close without applying

User presses `gx` on a line with a proposal sign
    │
    ▼
proposals/init.lua: reject(id)
    │
    ├── Emit AiChatProposalRejected
    ├── Clean up signs, extmarks, buffer-local keymaps
    │
    └── ui/proposals.lua: update_quickfix()
        (remove from quickfix list)
```

### Proposal Conflict / Expiry

```
User edits buffer within a proposal's target range
    │
    ▼
nvim_buf_attach on_lines callback
    │
    ├── Check if changed lines overlap any proposal's range
    │
    ├── If overlap:
    │   ├── proposals/init.lua: expire(id)
    │   ├── Update sign to AiChatProposalExpired (dimmed)
    │   ├── Update virtual text to "ai-chat: proposal outdated"
    │   └── Emit AiChatProposalExpired
    │
    └── If no overlap: no-op
```

### Placing Annotations (via /annotate)

```
User types `/annotate @buffer Walk me through this file`
    │
    ▼
commands/slash.lua: handle_annotate(prompt, context_refs)
    │
    ├── Collect context (@buffer, @selection, @file)
    ├── Build message with annotation-specific system prompt
    │   ("Annotate only lines that are non-obvious or important.
    │    Reference specific line numbers. Prefer fewer, higher-quality
    │    annotations over comprehensive coverage.")
    │
    ▼
init.lua: send() → provider streams response → chat buffer renders it
    │
    ▼
init.lua: on_done callback
    │
    ├── Parse structured annotations from response (multi-strategy):
    │   Strategy 1: exact format — [annotation: line N] summary
    │   Strategy 2: relaxed brackets — [line N], [Line N:], etc.
    │   Strategy 3: markdown headers — ### Line N: or **Line N:**
    │   Strategy 4: no parse → graceful degradation (chat still readable)
    │   Line numbers out of range are silently skipped.
    │   Duplicate line numbers keep the last annotation.
    │
    ├── annotations/init.lua: add(annotation)
    │   ├── Create annotation entry:
    │   │   { id, file, line, summary, detail, expanded = false }
    │   └── Append to state.annotations
    │
    ├── ui/annotations.lua (called by init, not by annotations/):
    │   │
    │   ├── For each annotation:
    │   │   ├── ui/overlays.lua: place_sign(bufnr, line, sign_opts)
    │   │   ├── ui/overlays.lua: place_virt_text(bufnr, line, summary)
    │   │   └── Set buffer-local keymaps: ]a, [a, za, gx
    │   │
    │   └── If target buffer is NOT loaded:
    │       └── Register BufRead autocmd (same pattern as proposals)
    │
    ├── vim.notify("[ai-chat] N annotations placed — ]a/[a to navigate")
    │
    └── Emit AiChatAnnotationCreated user event
```

### Expanding / Collapsing an Annotation

```
User presses `za` on an annotated line
    │
    ▼
init.lua: toggle_annotation(bufnr, line)
    │
    ├── annotations/init.lua: toggle(bufnr, line)
    │   ├── Find annotation matching this buffer and line
    │   └── Flip annotation.expanded (bool)
    │
    ├── ui/annotations.lua (called by init, not by annotations/):
    │   │
    │   ├── If now expanded:
    │   │   └── show_virt_lines(bufnr, line, detail)
    │   │       (nvim_buf_set_extmark with virt_lines = detail lines)
    │   │
    │   └── If now collapsed:
    │       └── hide_virt_lines(bufnr, line)
    │           (remove virt_lines from the extmark, keep sign + virt_text)
```

### Clearing Annotations

```
User runs `/annotate clear` or presses `<leader>ax`
    │
    ▼
init.lua: clear_annotations(bufnr)  -- or clear_all_annotations()
    │
    ├── annotations/init.lua: clear(bufnr)
    │   └── Remove annotation entries from state.annotations
    │
    ├── ui/annotations.lua (called by init, not by annotations/):
    │   ├── ui/overlays.lua: clear_namespace(bufnr, annotation_ns)
    │   │   (nvim_buf_clear_namespace wipes all extmarks in one call)
    │   └── Remove buffer-local keymaps
    │
    └── Emit AiChatAnnotationCleared user event
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

State is distributed across modules. Each module owns its slice:

```lua
-- ai-chat/init.lua — coordinator state only
local state = {
    config = {},              -- resolved configuration (owned by init)
    ui = {                    -- UI state (owned by init, managed by ui/init.lua)
        chat_bufnr = nil,
        chat_winid = nil,
        input_bufnr = nil,
        input_winid = nil,
        is_open = false,
    },
    _ollama_checked = false,  -- first-run Ollama detection (once per session)
}

-- ai-chat/conversation.lua — conversation state
local state = {
    id = "",              -- UUID
    messages = {},        -- { role, content, context, usage }
    provider = "",        -- active provider name
    model = "",           -- active model name
    created_at = 0,       -- timestamp
}

-- ai-chat/stream.lua — streaming state
local state = {
    active = false,
    cancel_fn = nil,      -- call to abort current generation
}

-- ai-chat/proposals/init.lua — proposal state
-- state.proposals: ordered list of AiChatProposal (ephemeral)
-- AiChatProposal:
-- {
--   id = "",             -- UUID
--   file = "",           -- absolute path to target file
--   description = "",    -- one-line human-readable intent
--   original_lines = {}, -- lines being replaced
--   proposed_lines = {}, -- replacement lines
--   range = { start, end }, -- 1-indexed line range in original
--   status = "pending",  -- pending|accepted|rejected|expired
--   created_at = 0,      -- timestamp
--   conversation_id = "",-- which conversation produced this
--   bufnr = nil,         -- buffer number if file is loaded
-- }

-- ai-chat/annotations/init.lua — annotation state
-- state.annotations: ordered list of AiChatAnnotation (ephemeral)
-- AiChatAnnotation:
-- {
--   id = "",             -- UUID
--   file = "",           -- absolute path to target file
--   line = 0,            -- 1-indexed target line
--   summary = "",        -- short text for collapsed virt_text
--   detail = {},         -- string[] for expanded virt_lines
--   expanded = false,    -- current display state
--   created_at = 0,      -- timestamp
--   conversation_id = "",-- which conversation produced this
--   bufnr = nil,         -- buffer number if file is loaded
-- }
```

State is not exposed directly. Access is through functions on each module:

```lua
-- init.lua (coordinator)
M.get_config()        -- returns resolved config

-- conversation.lua
M.get()               -- returns conversation table (read-only copy)
M.append_message(msg) -- add a message to conversation history
M.build_provider_messages(config) -- system prompt + history, truncated to budget

-- stream.lua
M.is_active()         -- returns boolean
M.cancel()            -- cancels active stream
```

## Buffer Lifecycle

The chat panel creates scratch buffers that can be destroyed by user actions
outside the plugin's keymaps (`:q`, `:bwipeout`, `:only`, `<C-w>c`). Three
autocommands in `init.lua`'s `M.open()` guard against inconsistent state:

| Event | Target | Action |
|-------|--------|--------|
| `WinClosed` | chat window | Cancel stream, stop spinner, destroy input, nil `state.ui`, fire `AiChatPanelClosed` |
| `BufWipeout` | chat buffer | Same cleanup, but skip `nvim_win_close` (buffer already gone) |
| `BufWipeout` | input buffer | Recreate input if chat window still valid; otherwise full close |

All three autocommands are registered in a single augroup (`ai-chat-lifecycle`)
cleared on each `M.open()` and deleted on `M.close()`. All callbacks are
wrapped in `vim.schedule()` to avoid issues during event processing.

**Interaction with proposals/annotations:** Proposal and annotation extmarks
live on *code buffers*, not the chat buffer. They survive chat panel
open/close. Their cleanup is managed by `ui/overlays.lua` and triggered by
`/annotate clear`, `gx`, or `<leader>aR` — not by chat lifecycle events.

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

**Framework:** plenary.nvim busted-style test runner via `nvim --headless`.
Tests run in a real neovim instance so `vim.api.*` calls work. Zero build step.

**Test runner (Makefile at project root):**

```makefile
test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

test-file:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedFile $(FILE)"
```

**Test categories:**
- Unit tests for pure logic: `config.lua`, `context/*.lua`, `util/*.lua`,
  `commands/slash.lua`, `conversation.lua`
- Integration tests for provider communication (mocked HTTP)
- UI tests are manual — buffer management is hard to test in isolation

**First 5 test files (v0.2):**

| File | Covers |
|------|--------|
| `tests/util/tokens_spec.lua` | Token estimation (pure function, easiest start) |
| `tests/context/init_spec.lua` | Context tag parsing (`@buffer`, `@file:path`, multiple tags) |
| `tests/config_spec.lua` | Config resolution, deep merge, validation |
| `tests/commands/slash_spec.lua` | Slash command routing and argument parsing |
| `tests/util/costs_spec.lua` | Cost estimation per provider, session accumulation |

**CI:** GitHub Actions with neovim stable + nightly. Runs `make test` on push
and PR. plenary.nvim is cloned automatically by `tests/minimal_init.lua`.
