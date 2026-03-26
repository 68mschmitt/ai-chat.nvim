# ai-chat.nvim — API Design

## Public API

The plugin exposes a single entry point: `require("ai-chat")`.

### setup(opts)

Called once during neovim initialization. Validates configuration, registers
commands and autocommands, sets up keybindings.

```lua
require("ai-chat").setup({
    -- See Configuration section below for full schema
})
```

### User-Facing Commands

| Command | Arguments | Description |
|---------|-----------|-------------|
| `:AiChat` | — | Toggle chat panel |
| `:AiChatOpen` | — | Open chat panel (no-op if already open) |
| `:AiChatClose` | — | Close chat panel |
| `:AiChatSend` | `[text]` | Send text as message (uses visual selection if no text) |
| `:AiChatClear` | — | Clear current conversation |
| `:AiChatModel` | `[model]` | Switch model (picker if no arg) |
| `:AiChatProvider` | `[provider]` | Switch provider (picker if no arg) |
| `:AiChatHistory` | — | Browse conversation history |
| `:AiChatSave` | `[name]` | Save current conversation |
| `:AiChatLog` | — | Open audit log buffer |
| `:AiChatCosts` | — | Show cost summary |
| `:AiChatKeys` | — | Show keybinding reference |
| `:AiChatConfig` | — | Show resolved configuration |

### Lua API

For programmatic use and integration with other plugins:

```lua
local chat = require("ai-chat")

-- Panel control
chat.toggle()                    -- Toggle chat panel
chat.open()                      -- Open chat panel
chat.close()                     -- Close chat panel
chat.is_open()                   -- Returns boolean

-- Messaging
chat.send(text, opts)            -- Send a message
                                 -- opts.context: table of context refs
                                 -- opts.callback: function(response)
chat.cancel()                    -- Cancel active generation
chat.is_streaming()              -- Returns boolean

-- Conversation
chat.clear()                     -- Clear conversation
chat.get_conversation()          -- Returns conversation table (read-only)
chat.save(name)                  -- Save conversation
chat.load(id)                    -- Load conversation by ID

-- Configuration (resolved state owned by config.lua)
chat.set_model(model_name)       -- Switch model
chat.set_provider(provider_name) -- Switch provider
chat.get_config()                -- Returns resolved config (delegates to config.get())
```

---

## Provider Interface

Every provider must implement a single function: `chat()`.

### Provider Contract

```lua
---@class AiChatProvider
---@field name string                    -- Provider identifier
---@field chat fun(messages, opts, callbacks): CancelFn

---@class AiChatMessage
---@field role "system"|"user"|"assistant"
---@field content string

---@class AiChatProviderOpts
---@field model string                   -- Model identifier
---@field temperature? number            -- 0.0 - 2.0, default 0.7
---@field max_tokens? number             -- Max response tokens, default 4096
---@field thinking? boolean              -- Extended thinking mode (provider-specific)
---@field stream? boolean                -- Enable streaming, default true

---@class AiChatCallbacks
---@field on_chunk fun(text: string)     -- Called for each streamed text fragment
---@field on_done fun(response: AiChatResponse) -- Called on completion
---@field on_error fun(error: AiChatError)      -- Called on failure

---@class AiChatResponse
---@field content string                 -- Full response text
---@field usage AiChatUsage              -- Token usage
---@field model string                   -- Model that actually responded
---@field thinking? string               -- Thinking content (if thinking mode)

---@class AiChatUsage
---@field input_tokens number
---@field output_tokens number
---@field thinking_tokens? number        -- For thinking mode

---@class AiChatError
---@field code string                    -- "rate_limit"|"auth"|"network"|"server"|"unknown"
---@field message string                 -- Human-readable error message
---@field retryable boolean              -- Whether automatic retry makes sense
---@field retry_after? number            -- Seconds to wait before retry (if known)

---@alias CancelFn fun()                -- Call to abort the request
```

### Provider Implementation Template

```lua
-- lua/ai-chat/providers/example.lua
local M = {}

M.name = "example"

--- Validate provider-specific configuration.
---@param config table  Provider config from setup()
---@return boolean ok
---@return string? error_message
function M.validate(config)
    if not config.api_key and not vim.env.EXAMPLE_API_KEY then
        return false, "No API key found. Set EXAMPLE_API_KEY or configure api_key."
    end
    return true
end

--- List available models for this provider.
---@param config table  Provider config from setup()
---@param callback fun(models: string[])
function M.list_models(config, callback)
    -- Async fetch of available models
    callback({ "example-small", "example-large" })
end

--- Send a chat request with streaming.
---@param messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param callbacks AiChatCallbacks
---@return CancelFn
function M.chat(messages, opts, callbacks)
    local config = require("ai-chat.config").get().providers.example
    local api_key = config.api_key or vim.env.EXAMPLE_API_KEY

    -- Build request body
    local body = vim.fn.json_encode({
        model = opts.model,
        messages = messages,
        temperature = opts.temperature or 0.7,
        max_tokens = opts.max_tokens or 4096,
        stream = true,
    })

    -- Make streaming HTTP request
    local handle = vim.system(
        { "curl", "--no-buffer", "-s",
          "-H", "Content-Type: application/json",
          "-H", "Authorization: Bearer " .. api_key,
          "-d", body,
          "https://api.example.com/v1/chat/completions" },
        {
            stdout = function(err, data)
                if err then
                    vim.schedule(function()
                        callbacks.on_error({
                            code = "network",
                            message = err,
                            retryable = true,
                        })
                    end)
                    return
                end
                if data then
                    -- Parse SSE chunks, extract text deltas
                    local text = parse_sse_chunk(data)
                    if text then
                        callbacks.on_chunk(text)
                    end
                end
            end,
        },
        function(result)
            -- on_exit callback
            if result.code ~= 0 then
                vim.schedule(function()
                    callbacks.on_error({
                        code = "network",
                        message = "curl exited with code " .. result.code,
                        retryable = true,
                    })
                end)
            else
                vim.schedule(function()
                    callbacks.on_done({
                        content = accumulated_text,
                        usage = parsed_usage,
                        model = opts.model,
                    })
                end)
            end
        end
    )

    -- Return cancel function
    return function()
        handle:kill("sigterm")
    end
end

return M
```

### Provider-Specific Notes

#### Ollama

- Endpoint: `http://localhost:11434/api/chat`
- Auth: None required
- Streaming: NDJSON (one JSON object per line)
- Usage: Reported in final chunk (`eval_count`, `prompt_eval_count`)
- Cost: Always $0.00

#### Anthropic

- Endpoint: `https://api.anthropic.com/v1/messages`
- Auth: `x-api-key` header from `ANTHROPIC_API_KEY`
- Streaming: SSE (`event: content_block_delta`)
- Thinking: Supported via `thinking` parameter
- Usage: Reported in `message_delta` event

#### Amazon Bedrock

- Endpoint: Regional Bedrock endpoints
- Auth: AWS Signature V4 (via `aws` CLI or IAM credentials)
- Streaming: Bedrock event stream format
- Note: Uses `aws` CLI for signing — no Lua AWS SDK needed.
  Command: `aws bedrock-runtime invoke-model-with-response-stream`

#### OpenAI-Compatible

- Endpoint: Configurable (default: `https://api.openai.com/v1/chat/completions`)
- Auth: `Authorization: Bearer` header
- Streaming: SSE (`data: {"choices":[{"delta":{"content":"..."}}]}`)
- Covers: OpenAI, Azure OpenAI, Groq, Together, LM Studio

---

## Context Interface

Context collectors follow a uniform interface:

```lua
---@class AiChatContextCollector
---@field name string                          -- e.g., "buffer", "selection"
---@field collect fun(args?: string): AiChatContext?

---@class AiChatContext
---@field type string                          -- "buffer"|"selection"|"diagnostics"|"diff"|"file"
---@field content string                       -- The actual context text
---@field source string                        -- Human-readable source label
---@field token_estimate number                -- Approximate token count
---@field metadata table                       -- Type-specific metadata
```

### Context Collector Examples

```lua
-- @buffer → collects entire current buffer
{
    type = "buffer",
    content = "local function setup(opts)\n  ...",
    source = "main.lua (142 lines)",
    token_estimate = 2847,
    metadata = {
        bufnr = 1,
        filename = "main.lua",
        filetype = "lua",
        line_count = 142,
    },
}

-- @selection → collects visual selection
{
    type = "selection",
    content = "local x = foo()\nlocal y = bar()",
    source = "main.lua:42-45",
    token_estimate = 12,
    metadata = {
        bufnr = 1,
        filename = "main.lua",
        filetype = "lua",
        start_line = 42,
        end_line = 45,
    },
}

-- @diagnostics → collects LSP diagnostics for current buffer
{
    type = "diagnostics",
    content = "Line 42: error: ...\nLine 87: warning: ...",
    source = "main.lua (3 errors, 2 warnings)",
    token_estimate = 150,
    metadata = {
        bufnr = 1,
        filename = "main.lua",
        error_count = 3,
        warning_count = 2,
    },
}
```

---

## Configuration Schema

```lua
---@class AiChatConfig
local defaults = {

    -- Active provider and model
    default_provider = "ollama",
    default_model = "llama3.2",

    -- Provider-specific configuration
    providers = {
        ollama = {
            host = "http://localhost:11434",
            -- No auth needed
        },
        anthropic = {
            -- api_key: reads from ANTHROPIC_API_KEY env var by default
            -- Explicitly setting api_key here is discouraged
            model = "claude-sonnet-4-20250514",
            max_tokens = 16000,
            thinking_budget = 10000,
        },
        bedrock = {
            region = "us-east-1",
            -- Credentials from AWS config/env, never in plugin config
            model = "anthropic.claude-sonnet-4-20250514-v1:0",
        },
        openai_compat = {
            endpoint = "https://api.openai.com/v1/chat/completions",
            -- api_key: reads from OPENAI_API_KEY env var by default
            model = "gpt-4o",
        },
    },

    -- UI configuration
    ui = {
        width = 0.25,           -- Fraction of editor width (0.0-1.0)
        min_width = 60,         -- Minimum columns
        max_width = 120,        -- Maximum columns
        position = "right",     -- "right" or "left"
        input_height = 3,       -- Default input area height (lines)
        input_max_height = 10,  -- Maximum input area height
        show_winbar = true,     -- Show status in winbar
        show_cost = true,       -- Show cost in winbar and message metadata
        show_tokens = true,     -- Show token counts in message metadata
        spinner = true,         -- Show spinner during generation
        separator = "─",        -- Character for separator lines
    },

    -- Chat behavior
    chat = {
        system_prompt = nil,    -- Custom system prompt (nil = use default)
        temperature = 0.7,
        max_tokens = 4096,
        thinking = false,       -- Extended thinking mode (provider-specific)
        auto_scroll = true,     -- Auto-scroll chat during streaming
        show_context = true,    -- Show context metadata on messages
    },

    -- History / persistence
    history = {
        enabled = true,
        max_conversations = 100,
        storage_path = nil,     -- nil = vim.fn.stdpath("data") .. "/ai-chat/history"
    },

    -- Keybindings
    keys = {
        -- Global (set to false to disable)
        toggle = "<leader>aa",
        send_selection = "<leader>as",
        quick_explain = "<leader>ae",
        quick_fix = "<leader>af",
        focus_input = "<leader>ac",
        switch_model = "<leader>am",
        switch_provider = "<leader>ap",

        -- Chat buffer (buffer-local)
        close = "q",
        cancel = "<C-c>",
        next_message = "]]",
        prev_message = "[[",
        next_code_block = "]b",
        prev_code_block = "[b",
        yank_code_block = "gY",
        apply_code_block = "ga",
        open_code_block = "gO",
        focus_input = "i",
        show_help = "?",

        -- Input buffer (buffer-local)
        submit_normal = "<CR>",
        submit_insert = "<C-CR>",
        recall_prev = "<Up>",
        recall_next = "<Down>",
    },

    -- Integrations (optional, auto-detected)
    integrations = {
        telescope = true,       -- Use telescope for pickers if available
        treesitter = true,      -- Use treesitter for code block highlighting
        cmp = true,             -- Use nvim-cmp for @context completion
    },

    -- Logging
    log = {
        enabled = true,
        level = "info",         -- "debug"|"info"|"warn"|"error"
        file = nil,             -- nil = vim.fn.stdpath("data") .. "/ai-chat/log.txt"
        max_size_mb = 10,       -- Rotate when log exceeds this size
    },
}
```

### Configuration Validation

On `setup()`, every config value is validated:

```lua
-- config.lua
function M.validate(config)
    vim.validate({
        default_provider = { config.default_provider, "string" },
        default_model = { config.default_model, "string" },
        ["ui.width"] = { config.ui.width, "number" },
        ["ui.position"] = {
            config.ui.position,
            function(v) return v == "right" or v == "left" end,
            "must be 'right' or 'left'"
        },
        -- ... all fields validated
    })

    -- Validate active provider is configured
    local provider = config.providers[config.default_provider]
    if not provider then
        return false, "Provider '" .. config.default_provider .. "' not configured"
    end

    -- Validate provider-specific config
    local ok, err = require("ai-chat.providers." .. config.default_provider).validate(provider)
    if not ok then
        return false, err
    end

    return true
end
```

---

## Events / Hooks

The plugin emits custom user events via `vim.api.nvim_exec_autocmds` for
extensibility:

| Event | Data | When |
|-------|------|------|
| `AiChatMessageSent` | `{ message, context }` | User sends a message |
| `AiChatResponseStart` | `{ provider, model }` | Response streaming begins |
| `AiChatResponseDone` | `{ response, usage }` | Response streaming completes |
| `AiChatResponseError` | `{ error }` | Response fails |
| `AiChatPanelOpened` | `{ winid, bufnr }` | Chat panel opens |
| `AiChatPanelClosed` | `{}` | Chat panel closes |
| `AiChatProviderChanged` | `{ provider, model }` | Provider or model switched |
| `AiChatConversationCleared` | `{}` | Conversation cleared |

### Planned Events (v0.4-v0.5)

| Event | Data | When |
|-------|------|------|
| `AiChatProposalCreated` | `{ proposal }` | AI proposes a code change |
| `AiChatProposalAccepted` | `{ proposal }` | User accepts a proposal |
| `AiChatProposalRejected` | `{ proposal }` | User rejects a proposal |
| `AiChatProposalExpired` | `{ proposal }` | Proposal invalidated by user edits |
| `AiChatAnnotationCreated` | `{ annotations }` | Annotations placed on a buffer |
| `AiChatAnnotationCleared` | `{ bufnr }` | Annotations removed from a buffer |

Usage:
```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatResponseDone",
    callback = function(args)
        local data = args.data
        print("Tokens used: " .. data.usage.input_tokens + data.usage.output_tokens)
    end,
})
```
