# ai-chat.nvim Codebase Exploration Summary

## 1. DIRECTORY TREE & FILE ORGANIZATION

### Core Structure (5,963 lines total in lua/)
```
lua/ai-chat/
├── init.lua                    (458 lines) — Main coordinator, public API
├── config.lua                  (266 lines) — Configuration schema & resolution
├── conversation.lua            (238 lines) — Conversation state management
├── stream.lua                  (165 lines) — Streaming orchestration
├── pipeline.lua                (196 lines) — Send pipeline (slash commands, context, provider)
├── keymaps.lua                 (73 lines)  — Global keymap registration
├── highlights.lua              (24 lines)  — Highlight group definitions
├── lifecycle.lua               (92 lines)  — Buffer lifecycle autocommands
├── errors.lua                  (70 lines)  — Error classification
├── health.lua                  (147 lines) — Health checks
│
├── ui/
│   ├── init.lua                (60 lines)  — UI coordinator (open/close)
│   ├── chat.lua                (321 lines) — Chat split window management
│   ├── input.lua               (293 lines) — Input area management
│   ├── render.lua              (423 lines) — Message rendering, code blocks
│   ├── diff.lua                (109 lines) — Diff-based code application
│   ├── thinking.lua            (237 lines) — Thinking block rendering
│   ├── spinner.lua             (61 lines)  — Loading spinner
│   └── render.lua              (423 lines) — Message rendering
│
├── context/
│   ├── init.lua                (108 lines) — Context coordinator
│   ├── buffer.lua              (61 lines)  — @buffer context collector
│   ├── selection.lua           (46 lines)  — @selection context collector
│   ├── file.lua                (46 lines)  — @file:path context collector
│   ├── diff.lua                (39 lines)  — @diff context collector
│   └── diagnostics.lua         (58 lines)  — @diagnostics context collector
│
├── commands/
│   ├── init.lua                (28 lines)  — Command router
│   └── slash.lua               (301 lines) — Slash command definitions
│
├── providers/
│   ├── init.lua                (74 lines)  — Provider registry
│   ├── anthropic.lua           (317 lines) — Anthropic provider
│   ├── bedrock.lua             (439 lines) — AWS Bedrock provider
│   ├── openai_compat.lua       (279 lines) — OpenAI-compatible provider
│   └── ollama.lua              (213 lines) — Ollama provider
│
├── history/
│   ├── init.lua                (96 lines)  — History browser
│   └── store.lua               (109 lines) — History persistence
│
├── util/
│   ├── log.lua                 (106 lines) — Logging
│   ├── costs.lua               (96 lines)  — Cost tracking
│   ├── tokens.lua              (28 lines)  — Token estimation
│   └── ui.lua                  (23 lines)  — UI utilities
│
└── models.lua                  (263 lines) — Model registry & pricing

tests/ (2,367 lines total)
├── harness.lua                 (178 lines) — Test framework
├── runner.lua                  (107 lines) — Test runner
├── verify.lua                  (411 lines) — Verification utilities
├── minimal_init.lua            (22 lines)  — Minimal Neovim init for tests
├── config_spec.lua             (104 lines)
├── conversation_spec.lua       (151 lines)
├── pipeline_spec.lua           (392 lines)
├── commands/
│   ├── router_spec.lua         (70 lines)
│   └── slash_spec.lua          (73 lines)
├── context/
│   └── init_spec.lua           (73 lines)
├── providers/
│   └── mock_http_spec.lua      (235 lines)
├── history/
│   └── store_spec.lua          (246 lines)
├── render/
│   └── thinking_spec.lua       (195 lines)
└── util/
    ├── costs_spec.lua          (71 lines)
    └── tokens_spec.lua         (39 lines)
```

---

## 2. MODULE DEPENDENCY GRAPH

### Coordinator Modules (own state, can require anything)
- `init.lua` — Main coordinator
  - Requires: config, conversation, stream, pipeline, ui, keymaps, highlights, lifecycle, history, models, providers, context
  - Exports: setup(), open(), close(), toggle(), send(), cancel(), clear(), get_conversation(), set_model(), set_provider(), set_thinking(), save(), load(), history(), show_keys(), show_config()

- `config.lua` — Configuration owner
  - Requires: (none)
  - Exports: resolve(), get(), set(), validate(), load_project_config(), history_path(), log_path()

- `stream.lua` — Streaming orchestration
  - Requires: errors, ui/spinner, ui/render
  - Exports: send(), cancel(), is_active()

- `pipeline.lua` — Send pipeline
  - Requires: context, providers, conversation, stream, ui/render, ui/input, commands, history, models, util/costs, util/log
  - Exports: send(), reset(), get_last_request()

### Boundary Modules (must NOT require config, models, or coordinator modules)
- `providers/*` — Provider implementations
  - Receive all config via function arguments
  - Never call require("ai-chat.config") or require("ai-chat.models")

- `context/*` — Context collectors
  - Pure functions, no state
  - Receive all config via arguments

- `ui/*` — UI modules
  - Receive config via arguments
  - Can call each other

### Dependency Flow
```
init.lua (coordinator)
  ├─→ config.lua (owns resolved config)
  ├─→ conversation.lua (owns conversation state)
  ├─→ stream.lua (owns streaming state)
  │   ├─→ ui/spinner.lua
  │   └─→ ui/render.lua
  ├─→ pipeline.lua (orchestrates send)
  │   ├─→ context/init.lua
  │   ├─→ providers/init.lua
  │   ├─→ commands/init.lua
  │   └─→ stream.lua
  ├─→ ui/init.lua
  │   ├─→ ui/chat.lua
  │   ├─→ ui/input.lua
  │   └─→ ui/render.lua
  ├─→ keymaps.lua
  ├─→ highlights.lua
  ├─→ lifecycle.lua
  ├─→ history/init.lua
  └─→ models.lua
```

---

## 3. THE `ga` (APPLY CODE) WORKFLOW — END-TO-END

### Flow Diagram
```
User presses 'ga' in chat buffer
  ↓
ui/chat.lua:_apply_code_block()
  ↓
ui/render.lua:get_code_block_at_cursor(bufnr, winid)
  ├─ Scans buffer for ```language fences
  ├─ Finds block containing cursor
  └─ Returns { language, content, start_line, end_line }
  ↓
ui/diff.lua:apply(block)
  ├─ Determines target buffer (alternate buffer → most recent code buffer)
  ├─ Enables diff mode on original buffer (vim.cmd("diffthis"))
  ├─ Creates vertical split with suggested content
  ├─ Sets up suggested buffer with:
  │  ├─ Content from block.content
  │  ├─ Filetype from block.language (or target filetype)
  │  ├─ buftype="nofile", bufhidden="wipe"
  │  └─ Name "ai-chat://suggested"
  ├─ Enables diff mode on suggested buffer (vim.cmd("diffthis"))
  ├─ Shows help message: "use ]c/[c to navigate, do/dp to apply, :diffoff|only to finish"
  └─ Sets up BufWipeout autocmd to clean up diff mode when suggested buffer closes
  ↓
User reviews diff and applies changes using Vim's diff commands
  ├─ ]c / [c — navigate hunks
  ├─ do — diff obtain (copy from suggested to original)
  ├─ dp — diff put (copy from original to suggested)
  └─ :diffoff|only — finish and close suggested buffer
```

### Key Implementation Details

**ui/chat.lua:_apply_code_block() (lines 269-280)**
```lua
function M._apply_code_block()
    if not state.bufnr or not state.winid then
        return
    end
    local block = require("ai-chat.ui.render").get_code_block_at_cursor(state.bufnr, state.winid)
    if block then
        require("ai-chat.ui.diff").apply(block)
    else
        vim.notify("[ai-chat] No code block under cursor", vim.log.levels.WARN)
    end
end
```

**ui/render.lua:get_code_block_at_cursor() (lines 290-340)**
- Scans all lines in buffer for ```language fences
- Tracks opening/closing fence pairs
- Finds block containing cursor (0-indexed comparison)
- Returns block with language, content (lines between fences), start_line, end_line

**ui/diff.lua:apply() (lines 8-87)**
- Finds target buffer: alternate buffer (#) → most recent code buffer
- Validates target has a file name
- Focuses code area (wincmd p)
- Enables diff on original: `vim.cmd("diffthis")`
- Creates vertical split: `vim.cmd("vnew")`
- Sets up suggested buffer with content, filetype, options
- Enables diff on suggested: `vim.cmd("diffthis")`
- Sets up BufWipeout autocmd to clean up diff mode

### Code Block Detection Algorithm
```lua
-- Scan for fences: ```language (opening) and ``` (closing)
for i, line in ipairs(lines) do
    if not current_block then
        local lang = line:match("^```(%w+)")  -- Opening fence
        if lang then
            current_block = { start = idx, language = lang }
        end
    else
        if line:match("^```%s*$") then  -- Closing fence
            current_block.finish = idx
            table.insert(blocks, current_block)
            current_block = nil
        end
    end
end
```

---

## 4. SIGN, EXTMARK, AND VIRTUAL TEXT USAGE

### Extmarks (Primary mechanism)
**Namespace:** `ai-chat-render` (created in ui/render.lua:10)

**Usage Locations:**

1. **ui/render.lua:61-64** — Message metadata virtual text
   ```lua
   vim.api.nvim_buf_set_extmark(bufnr, ns, start_line, 0, {
       virt_text = { { " [" .. table.concat(meta_parts, " | ") .. "]", "AiChatMeta" } },
       virt_text_pos = "eol",
   })
   ```
   - Shows context tags (@buffer, @selection) and token counts
   - Example: `[" [@buffer: main.lua | 150->200]", "AiChatMeta" ]`

2. **ui/render.lua:69-72** — Message header highlighting
   ```lua
   vim.api.nvim_buf_set_extmark(bufnr, ns, start_line, 0, {
       end_col = #header,
       hl_group = hl_group,  -- "AiChatUser" or "AiChatAssistant"
   })
   ```

3. **ui/render.lua:125-128** — Assistant header in streaming
   ```lua
   vim.api.nvim_buf_set_extmark(bufnr, ns, header_line, 0, {
       end_col = #"## Assistant",
       hl_group = "AiChatAssistant",
   })
   ```

4. **ui/render.lua:236-240** — Streaming response metadata
   ```lua
   vim.api.nvim_buf_set_extmark(bufnr, ns, header_line, 0, {
       virt_text = { { " [" .. table.concat(meta_parts, " | ") .. "]", "AiChatMeta" } },
       virt_text_pos = "eol",
   })
   ```

5. **ui/render.lua:275-278** — Code block syntax highlighting during streaming
   ```lua
   pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, write_line + i, 0, {
       hl_group = "AiChatMeta",
   })
   ```

6. **ui/render.lua:361-363, 371-373** — Code fence dimming
   ```lua
   pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, abs_line, 0, {
       line_hl_group = "AiChatMeta",
   })
   ```

7. **ui/render.lua:394-404** — Bold delimiter concealment (fallback when treesitter unavailable)
   ```lua
   pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_nr, s - 1, {
       conceal = "",
   })
   ```

8. **ui/thinking.lua:133-146** — Thinking block styling
   ```lua
   pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_nr, 0, {
       hl_group = "AiChatThinking",
   })
   ```

### Signs
**Not used.** Sign column is explicitly disabled:
- ui/chat.lua:38 — `vim.wo[winid].signcolumn = "no"`
- ui/input.lua:41 — `vim.wo[winid].signcolumn = "no"`

### Virtual Text
**Used via extmarks** (see above). Examples:
- Message metadata: `[" [@buffer: main.lua | 150->200]", "AiChatMeta" ]`
- Streaming status: `[" [streaming...]", "AiChatSpinner" ]`

---

## 5. USER EVENT PATTERNS

### Events Dispatched (via `vim.api.nvim_exec_autocmds`)

**init.lua:118-121** — Panel opened
```lua
pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "AiChatPanelOpened",
    data = { winid = state.ui.chat_winid, bufnr = state.ui.chat_bufnr },
})
```

**init.lua:139** — Panel closed
```lua
pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatPanelClosed" })
```

**init.lua:204** — Conversation cleared
```lua
pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatConversationCleared" })
```

**init.lua:293-296** — Provider changed
```lua
pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "AiChatProviderChanged",
    data = { provider = provider_name, model = conv.get_model() },
})
```

**pipeline.lua:140-143** — Response started
```lua
pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "AiChatResponseStart",
    data = { provider = provider_name, model = conv.get_model() },
})
```

**pipeline.lua:178-181** — Response done
```lua
pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "AiChatResponseDone",
    data = { response = response, usage = response.usage },
})
```

**pipeline.lua:188-191** — Response error
```lua
pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "AiChatResponseError",
    data = { error = err },
})
```

**lifecycle.lua:22** — Panel closed (from lifecycle guard)
```lua
pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatPanelClosed" })
```

### Event Usage Pattern
- All events wrapped in `pcall()` for safety
- Events use `User` event type (custom events)
- Data passed via `data` table
- Users can listen: `autocmd User AiChatPanelOpened ...`

---

## 6. TEST INFRASTRUCTURE

### Test Framework (tests/harness.lua)
- **Zero external dependencies** — custom minimal test harness
- **API:** `describe()`, `it()`, `before_each()`, `after_each()`
- **Assertions:** `assert()`, `assert.equals()`, `assert.truthy()`, `assert.is_table()`, `assert.is_nil()`, `assert.is_true()`, `assert.is_false()`

### Test Organization
```
tests/
├── harness.lua              — Test framework (describe/it/assert)
├── runner.lua               — Test runner (loads and executes tests)
├── verify.lua               — Verification utilities (mocking, fixtures)
├── minimal_init.lua         — Minimal Neovim init for tests
│
├── config_spec.lua          — Config resolution & validation
├── conversation_spec.lua    — Conversation state management
├── pipeline_spec.lua        — Send pipeline (largest test file)
│
├── commands/
│   ├── router_spec.lua      — Command routing
│   └── slash_spec.lua       — Slash command execution
│
├── context/
│   └── init_spec.lua        — Context collection
│
├── providers/
│   └── mock_http_spec.lua   — Provider HTTP mocking
│
├── history/
│   └── store_spec.lua       — History persistence
│
├── render/
│   └── thinking_spec.lua    — Thinking block rendering
│
└── util/
    ├── costs_spec.lua       — Cost calculation
    └── tokens_spec.lua      — Token estimation
```

### Test Patterns
- **Mocking:** verify.lua provides mock providers and HTTP utilities
- **Fixtures:** Minimal Neovim init for isolated test environment
- **Coverage:** Config, conversation, pipeline, commands, context, providers, history, rendering, utilities

### Running Tests
```bash
make test  # Runs all tests via runner.lua
```

---

## 7. EXISTING PROPOSAL-RELATED CODE

**None found.** The codebase has:
- `/review` slash command (code review template)
- `ui/diff.lua` (diff-based code application)
- But **no proposal/approval/rejection workflow**

This is a greenfield feature area.

---

## 8. KEY ARCHITECTURAL PATTERNS

### 1. Coordinator Pattern (init.lua)
- Single coordinator owns UI state and module wiring
- Lazy-loads heavy modules (conversation, stream, pipeline)
- All public API flows through coordinator

### 2. Boundary Rule
- Coordinator modules (init, config, stream, pipeline) can require anything
- Boundary modules (providers, context, ui) receive all dependencies as arguments
- Prevents circular dependencies and enables testing

### 3. State Ownership
- `config.lua` — owns resolved configuration
- `conversation.lua` — owns conversation messages and metadata
- `stream.lua` — owns streaming state (active, cancel_fn, retry_count)
- `init.lua` — owns UI state (bufnr, winid, is_open)

### 4. Namespace Isolation
- Extmarks use single namespace: `ai-chat-render`
- Autocommand groups: `ai-chat-lifecycle`, `ai-chat-code-buffer`
- Highlight groups: `AiChatUser`, `AiChatAssistant`, `AiChatMeta`, etc.

### 5. Error Handling
- Errors classified in `errors.lua` (RETRYABLE, FATAL, UNKNOWN)
- Stream auto-retries with exponential backoff (2s, 4s, 8s)
- All external calls wrapped in `pcall()` for safety

### 6. Message Building
- Context inlined into user message content (XML-like tags)
- System prompt + conversation history + context window truncation
- Token estimation for budget management

---

## 9. SEND PIPELINE FLOW (pipeline.lua)

```
M.send(text, opts, ui_state, deps)
  ├─ Ensure panel is open
  ├─ Route slash commands (if text starts with "/")
  ├─ Provider preflight check (once per session per provider)
  ├─ Collect context (@buffer, @selection, @diagnostics, @diff, @file)
  ├─ Strip @tags from message text
  ├─ Build user message { role, content, context, timestamp }
  ├─ Append to conversation
  ├─ Render message in chat buffer
  ├─ Build provider messages (system prompt + history + context)
  ├─ Apply context window truncation if needed
  ├─ Dispatch AiChatResponseStart event
  ├─ Call stream.send() with provider
  │  ├─ Start spinner
  │  ├─ Call provider.chat() with streaming callbacks
  │  ├─ Accumulate chunks in line buffer
  │  ├─ Render streamed content in real-time
  │  ├─ On done: finalize rendering, record costs, save history
  │  ├─ On error: retry if retryable, else fail
  │  └─ Dispatch AiChatResponseDone or AiChatResponseError event
  └─ Return
```

---

## 10. CONFIGURATION STRUCTURE

### Defaults (config.lua:13-111)
```lua
{
    default_provider = "ollama",
    default_model = "llama3.2",
    providers = {
        ollama = { host = "http://localhost:11434" },
        anthropic = { model = "claude-sonnet-4-20250514", max_tokens = 16000, thinking_budget = 10000 },
        bedrock = { region = "us-east-1", model = "anthropic.claude-sonnet-4-20250514-v1:0" },
        openai_compat = { endpoint = "https://api.openai.com/v1/chat/completions", model = "gpt-4o" },
    },
    ui = {
        width = 0.25,
        min_width = 60,
        max_width = 120,
        position = "right",
        input_height = 3,
        input_max_height = 10,
        show_winbar = true,
        show_cost = true,
        show_tokens = true,
        spinner = true,
    },
    chat = {
        system_prompt = nil,
        temperature = 0.7,
        max_tokens = 4096,
        thinking = false,
        show_thinking = true,
        auto_scroll = true,
        show_context = true,
    },
    history = { enabled = true, max_conversations = 100, storage_path = nil },
    keys = {
        toggle = "<leader>aa",
        send_selection = "<leader>as",
        quick_explain = "<leader>ae",
        quick_fix = "<leader>af",
        focus_input = "<leader>ac",
        switch_model = "<leader>am",
        switch_provider = "<leader>ap",
        close = "q",
        cancel = "<C-c>",
        next_message = "]]",
        prev_message = "[[",
        next_code_block = "]b",
        prev_code_block = "[b",
        yank_code_block = "gY",
        apply_code_block = "ga",
        open_code_block = "gO",
        show_help = "?",
        submit_normal = "<CR>",
        submit_insert = "<C-CR>",
        recall_prev = "<Up>",
        recall_next = "<Down>",
    },
    integrations = { treesitter = true },
    log = { enabled = true, level = "info", file = nil, max_size_mb = 10 },
}
```

### Per-Project Config (.ai-chat.lua)
- Allowed keys: `system_prompt`, `default_provider`, `default_model`, `temperature`, `providers.*`
- Loaded via `dofile()` (not require) for live editing
- Merged with defaults during setup

---

## 11. HIGHLIGHT GROUPS

**highlights.lua:9-22**
```lua
AiChatUser              → Title
AiChatAssistant         → Statement
AiChatMeta              → Comment
AiChatError             → DiagnosticError
AiChatWarning           → DiagnosticWarn
AiChatSpinner           → DiagnosticInfo
AiChatSeparator         → WinSeparator
AiChatInputPrompt       → Question
AiChatContextTag        → Tag
AiChatThinking          → Comment
AiChatThinkingHeader    → DiagnosticInfo
```

All use `default = true` so users can override in their colorscheme.

---

## 12. LIFECYCLE AUTOCOMMANDS

**lifecycle.lua:11-90**
- Registered in `ai-chat-lifecycle` augroup (cleared on each open, deleted on close)
- Guards against inconsistent state when windows/buffers closed externally

**Guards:**
1. **WinClosed** on chat window — cancel stream, destroy input, reset state
2. **BufWipeout** on chat buffer — cancel stream, destroy input, reset state
3. **BufWipeout** on input buffer — recreate input or reset state

All callbacks use `vim.schedule()` for safety.

---

## 13. CONTEXT COLLECTION

**context/init.lua:38-71**
```
M.collect(text, explicit_contexts)
  ├─ Parse @tags from message text (regex: @(\S+))
  ├─ Merge with explicit contexts (deduplicate)
  ├─ For each tag:
  │  ├─ Look up collector (buffer, selection, diagnostics, diff, file)
  │  ├─ Call collector.collect(args)
  │  └─ Append result to results
  └─ Return results
```

**Collectors:**
- `@buffer` — Current buffer content
- `@selection` — Last visual selection
- `@diagnostics` — LSP diagnostics in current buffer
- `@diff` — Diff of current buffer
- `@file:path` — Specific file content

---

## 14. CONVERSATION STATE

**conversation.lua:61-161**
```lua
M.new(provider, model)              — Create new conversation
M.restore(conversation)             — Restore from history
M.get()                             — Get read-only copy
M.append(message)                   — Add message
M.build_provider_messages(config)   — Build messages for provider (with truncation)
M.set_provider(provider)            — Switch provider
M.set_model(model)                  — Switch model
```

**Message Structure:**
```lua
{
    role = "user" | "assistant",
    content = string,
    context = AiChatContext[]?,      -- Only on user messages
    usage = { input_tokens, output_tokens }?,
    model = string?,
    thinking = string?,
    timestamp = number,
}
```

**Context Window Truncation:**
- Per-model windows (hardcoded in model_context_windows table)
- Per-provider fallback (provider_context_windows table)
- User config override (config.providers[provider].context_window)
- Strategy: Remove oldest messages first, preserve system prompt and most recent user message

---

## 15. STREAMING ARCHITECTURE

**stream.lua:58-155**
```
M.send(provider, provider_messages, opts, ui_state, callbacks)
  ├─ Check if already streaming
  ├─ Call M._do_send()
  │  ├─ Start spinner
  │  ├─ Create stream renderer (begin_response)
  │  ├─ Call provider.chat() with callbacks:
  │  │  ├─ on_chunk(text) — append to stream renderer
  │  │  ├─ on_done(response) — finalize rendering, record costs, dispatch event
  │  │  └─ on_error(err) — check if retryable, retry or fail
  │  └─ Return cancel_fn
  ├─ On error (if retryable):
  │  ├─ Show retry message in stream render
  │  ├─ Schedule retry with exponential backoff (2s, 4s, 8s)
  │  └─ Call M._do_send() again
  └─ Return
```

**Retry Policy:**
- MAX_RETRIES = 3
- Only RETRYABLE errors (classified in errors.lua) are retried
- Exponential backoff: 2^attempt (capped at 8s)

---

## 16. SEND() FUNCTION (init.lua:153-176)

**Public API:**
```lua
M.send(text, opts)
  ├─ Ensure initialized
  ├─ If no text, get from input buffer
  ├─ If empty, return
  ├─ Call pipeline.send(text, opts, state.ui, {
  │  ├─ conversation = get_conversation()
  │  ├─ stream = get_stream()
  │  ├─ config = config
  │  ├─ open_fn = M.open
  │  └─ update_winbar_fn = M._update_winbar
  │  })
  └─ Return
```

**Options:**
```lua
{
    context = string[]?,        -- Explicit context tags (@buffer, @selection, etc.)
    callback = fun(response)?   -- Called when response is done
}
```

---

## 17. SUMMARY FOR PROPOSAL FEATURE

### What Exists
- ✅ Diff split infrastructure (ui/diff.lua)
- ✅ Code block detection (ui/render.lua:get_code_block_at_cursor)
- ✅ User event system (vim.api.nvim_exec_autocmds)
- ✅ Extmark system for UI annotations
- ✅ Slash command framework (commands/slash.lua)
- ✅ Configuration system with per-project overrides

### What's Missing (for proposal feature)
- ❌ Proposal state management (new module)
- ❌ Proposal diff split variant (extend ui/diff.lua)
- ❌ Proposal approval/rejection commands (extend commands/slash.lua)
- ❌ Proposal event dispatches (AiChatProposalCreated, AiChatProposalApproved, etc.)
- ❌ Proposal UI indicators (extmarks for approval status)
- ❌ Proposal history/persistence (extend history/store.lua)

### Recommended Architecture
1. **New module:** `lua/ai-chat/proposals.lua` (proposal state management)
2. **Extend:** `lua/ai-chat/ui/diff.lua` (add proposal mode)
3. **Extend:** `lua/ai-chat/commands/slash.lua` (add /approve, /reject commands)
4. **Extend:** `lua/ai-chat/init.lua` (add public API: create_proposal, approve_proposal, reject_proposal)
5. **Extend:** `lua/ai-chat/lifecycle.lua` (guard proposal state on panel close)
6. **Extend:** `lua/ai-chat/history/store.lua` (persist proposals with conversations)

