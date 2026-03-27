# ai-chat.nvim Quick Reference for Proposal Feature Development

## File Locations Quick Map

| Feature | Primary File | Related Files |
|---------|--------------|---------------|
| **Code Application (ga)** | `ui/diff.lua` (109 lines) | `ui/chat.lua:269-280`, `ui/render.lua:290-340` |
| **Code Block Detection** | `ui/render.lua:290-340` | `ui/chat.lua:_jump_code_block()` |
| **User Events** | `init.lua:118-204` | `pipeline.lua:140-191`, `lifecycle.lua:22` |
| **Extmarks/UI** | `ui/render.lua:61-404` | `ui/thinking.lua:133-146` |
| **Slash Commands** | `commands/slash.lua` (301 lines) | `commands/init.lua` (28 lines) |
| **Configuration** | `config.lua` (266 lines) | `init.lua:58-87` |
| **Conversation State** | `conversation.lua` (238 lines) | `pipeline.lua:100-161` |
| **Streaming** | `stream.lua` (165 lines) | `pipeline.lua:149-193` |

---

## Key Functions for Proposal Feature

### Code Block Detection
```lua
-- Location: ui/render.lua:290-340
ui.render.get_code_block_at_cursor(bufnr, winid)
  → { language, content, start_line, end_line }
```

### Diff Application
```lua
-- Location: ui/diff.lua:8-87
ui.diff.apply(block)
  -- Opens diff split with suggested content
  -- Sets up BufWipeout autocmd for cleanup
```

### User Events
```lua
-- Location: init.lua:118-121, pipeline.lua:140-191
vim.api.nvim_exec_autocmds("User", {
    pattern = "AiChatPanelOpened|Closed|ResponseStart|ResponseDone|ResponseError",
    data = { ... }
})
```

### Extmark Annotations
```lua
-- Location: ui/render.lua:61-72
vim.api.nvim_buf_set_extmark(bufnr, ns, line, col, {
    virt_text = { { text, "AiChatMeta" } },
    virt_text_pos = "eol",
    hl_group = "AiChatUser|AiChatAssistant|AiChatMeta",
})
```

### Slash Commands
```lua
-- Location: commands/slash.lua:8-301
M.commands.command_name = function(args, state)
    -- args: string after command name
    -- state: { config, conversation }
end
```

---

## Extmark Namespace

```lua
-- Single namespace for all UI annotations
local ns = vim.api.nvim_create_namespace("ai-chat-render")

-- Used in:
-- - ui/render.lua (message headers, metadata, code blocks)
-- - ui/thinking.lua (thinking block styling)
```

---

## Highlight Groups Available

```lua
AiChatUser              -- Message headers (user)
AiChatAssistant         -- Message headers (assistant)
AiChatMeta              -- Metadata, code fences, context tags
AiChatError             -- Error messages
AiChatWarning           -- Warning messages
AiChatSpinner           -- Loading spinner
AiChatThinking          -- Thinking block content
AiChatThinkingHeader    -- Thinking block header
```

---

## Autocommand Groups

```lua
-- Lifecycle guards (cleared on open, deleted on close)
vim.api.nvim_create_augroup("ai-chat-lifecycle", { clear = true })

-- Code buffer tracking (persistent)
vim.api.nvim_create_augroup("ai-chat-code-buffer", { clear = true })
```

---

## Configuration Access Pattern

```lua
-- In coordinator modules (init.lua, pipeline.lua, stream.lua):
local config = require("ai-chat.config").get()

-- In boundary modules (providers, context, ui):
-- Receive config as function argument:
function M.apply(block, config)
    -- Use config here
end
```

---

## Message Structure

```lua
{
    role = "user" | "assistant",
    content = string,
    context = {
        {
            type = "buffer" | "selection" | "diagnostics" | "diff" | "file",
            source = string,  -- e.g., "main.lua", "selection"
            content = string,
            token_estimate = number,
        }
    }?,
    usage = {
        input_tokens = number,
        output_tokens = number,
    }?,
    model = string?,
    thinking = string?,
    timestamp = number,
}
```

---

## State Ownership

| Module | Owns | Access Pattern |
|--------|------|-----------------|
| `config.lua` | Resolved configuration | `require("ai-chat.config").get()` |
| `conversation.lua` | Messages, provider, model | `require("ai-chat.conversation").get()` |
| `stream.lua` | Streaming state, retry count | `require("ai-chat.stream").is_active()` |
| `init.lua` | UI state (bufnr, winid) | Internal to coordinator |

---

## Boundary Rule Violations (DON'T DO THIS)

```lua
-- ❌ WRONG: In providers/anthropic.lua
local config = require("ai-chat.config").get()

-- ✅ RIGHT: In providers/anthropic.lua
function M.chat(messages, opts, callbacks)
    -- opts contains all needed config
end

-- ❌ WRONG: In context/buffer.lua
local models = require("ai-chat.models")

-- ✅ RIGHT: In context/buffer.lua
function M.collect(args)
    -- Pure function, no dependencies
end
```

---

## Testing Patterns

```lua
-- tests/harness.lua provides:
describe("Feature", function()
    before_each(function()
        -- Setup
    end)
    
    it("does something", function()
        assert.equals(expected, actual)
        assert.truthy(value)
        assert.is_table(value)
    end)
    
    after_each(function()
        -- Cleanup
    end)
end)
```

---

## Diff Mode Cleanup Pattern

```lua
-- Location: ui/diff.lua:71-86
vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = suggested_bufnr,
    once = true,
    callback = function()
        -- Turn off diff in original buffer
        if vim.api.nvim_buf_is_valid(target_bufnr) then
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_get_buf(win) == target_bufnr then
                    vim.api.nvim_win_call(win, function()
                        vim.cmd("diffoff")
                    end)
                end
            end
        end
    end,
})
```

---

## Event Dispatch Pattern

```lua
-- Always wrap in pcall for safety
pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "AiChatEventName",
    data = { key = value },
})

-- Users listen with:
-- autocmd User AiChatEventName ...
```

---

## Code Block Fence Detection

```lua
-- Opening fence: ```language
local lang = line:match("^```(%w+)")

-- Closing fence: ``` (with optional whitespace)
local is_closing = line:match("^```%s*$")

-- Cursor position check (0-indexed):
if cursor_line >= block.start and cursor_line <= block.finish then
    -- Cursor is in this block
end
```

---

## Proposal Feature Integration Points

### 1. Extend ui/diff.lua
```lua
-- Add proposal mode parameter
function M.apply(block, opts)
    opts = opts or {}
    if opts.proposal_mode then
        -- Create proposal diff split instead of direct application
    else
        -- Current behavior
    end
end
```

### 2. Add Slash Commands
```lua
-- In commands/slash.lua
M.commands.approve = function(args, state)
    -- Approve current proposal
end

M.commands.reject = function(args, state)
    -- Reject current proposal
end
```

### 3. Dispatch Events
```lua
-- In proposals.lua (new module)
pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "AiChatProposalCreated",
    data = { proposal_id = id, block = block },
})
```

### 4. Add Extmarks for Status
```lua
-- In proposals.lua or ui/diff.lua
vim.api.nvim_buf_set_extmark(bufnr, ns, line, 0, {
    virt_text = { { " [PENDING APPROVAL]", "AiChatWarning" } },
    virt_text_pos = "eol",
})
```

---

## File Modification Checklist for Proposal Feature

- [ ] Create `lua/ai-chat/proposals.lua` (new state management)
- [ ] Extend `lua/ai-chat/ui/diff.lua` (add proposal mode)
- [ ] Extend `lua/ai-chat/commands/slash.lua` (add /approve, /reject)
- [ ] Extend `lua/ai-chat/init.lua` (add public API)
- [ ] Extend `lua/ai-chat/lifecycle.lua` (guard proposal state)
- [ ] Extend `lua/ai-chat/highlights.lua` (add AiChatProposal* groups)
- [ ] Extend `lua/ai-chat/history/store.lua` (persist proposals)
- [ ] Add tests in `tests/proposals_spec.lua`

---

## Common Patterns to Reuse

### 1. Lazy Module Loading (from init.lua)
```lua
local conversation -- ai-chat.conversation

local function get_conversation()
    if not conversation then
        conversation = require("ai-chat.conversation")
    end
    return conversation
end
```

### 2. State Table Pattern (from stream.lua)
```lua
local state = {
    active = false,
    cancel_fn = nil,
    retry_count = 0,
}

function M.is_active()
    return state.active
end
```

### 3. Callback Pattern (from stream.lua)
```lua
function M.send(provider, messages, opts, ui_state, callbacks)
    state.cancel_fn = provider.chat(messages, opts, {
        on_chunk = function(text) ... end,
        on_done = function(response) ... end,
        on_error = function(err) ... end,
    })
end
```

### 4. Validation Pattern (from config.lua)
```lua
function M.validate(config)
    if type(config.field) ~= "expected_type" then
        return false, "error message"
    end
    return true
end
```

---

## Dependency Injection Pattern

```lua
-- In pipeline.lua (coordinator module):
function M.send(text, opts, ui_state, deps)
    local config = deps.config
    local conv = deps.conversation
    local stream = deps.stream
    -- Use injected dependencies
end

-- In init.lua (caller):
get_pipeline().send(text, opts, state.ui, {
    conversation = get_conversation(),
    stream = get_stream(),
    config = config,
    open_fn = function() M.open() end,
    update_winbar_fn = function() M._update_winbar() end,
})
```

---

## Error Handling Pattern

```lua
-- All external calls wrapped in pcall
pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "Event" })
pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, col, opts)
pcall(require("ai-chat.ui.input").destroy)

-- Errors classified in errors.lua
if errors.is_retryable(err) then
    -- Retry with backoff
else
    -- Fail immediately
end
```

