# Autocmd Events

ai-chat.nvim fires User autocmds at key lifecycle points. These events allow you to hook into the plugin's behavior and react to state changes.

## Events

### AiChatPanelOpened

Fired when the chat panel is opened.

**Location:** `lua/ai-chat/init.lua:131`

**Payload:**
```lua
{
    winid = number,  -- Window ID of the chat buffer
    bufnr = number,  -- Buffer number of the chat buffer
}
```

**Example:**
```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatPanelOpened",
    callback = function(event)
        local winid = event.data.winid
        local bufnr = event.data.bufnr
        print("Chat panel opened: winid=" .. winid .. ", bufnr=" .. bufnr)
    end,
})
```

### AiChatPanelClosed

Fired when the chat panel is closed.

**Location:** `lua/ai-chat/init.lua:152`

**Payload:** *(none)*

**Example:**
```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatPanelClosed",
    callback = function()
        print("Chat panel closed")
    end,
})
```

### AiChatConversationCleared

Fired when the conversation is cleared (`:AiClear` command or `M.clear()` call).

**Location:** `lua/ai-chat/init.lua:219`

**Payload:** *(none)*

**Example:**
```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatConversationCleared",
    callback = function()
        print("Conversation cleared")
    end,
})
```

### AiChatProviderChanged

Fired when the active provider is changed.

**Location:** `lua/ai-chat/init.lua:310`

**Payload:**
```lua
{
    provider = string,  -- Provider name (e.g., "anthropic", "ollama")
    model = string,     -- Model name (e.g., "claude-sonnet-4-20250514")
}
```

**Example:**
```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatProviderChanged",
    callback = function(event)
        local provider = event.data.provider
        local model = event.data.model
        print("Provider changed to " .. provider .. " with model " .. model)
    end,
})
```

### AiChatResponseStart

Fired when a response from the AI begins streaming.

**Location:** `lua/ai-chat/pipeline.lua:110`

**Payload:**
```lua
{
    provider = string,  -- Provider name (e.g., "anthropic", "ollama")
    model = string,     -- Model name
}
```

**Example:**
```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatResponseStart",
    callback = function(event)
        print("Response started from " .. event.data.provider)
    end,
})
```

### AiChatResponseDone

Fired when a response completes successfully.

**Location:** `lua/ai-chat/pipeline.lua:148`

**Payload:**
```lua
{
    response = AiChatResponse,  -- Full response object with content, usage, model, thinking
    usage = table,              -- Token usage (DEPRECATED: use response.usage instead)
    ttft_ms = number,           -- Time to first token in milliseconds
}
```

**Response object structure:**
```lua
{
    content = string,           -- The assistant's response text
    usage = {
        input_tokens = number,
        output_tokens = number,
        thinking_tokens = number,  -- Only for Claude with extended thinking
    },
    model = string,             -- Model that generated the response
    thinking = string,          -- Extended thinking content (if enabled)
    timestamp = number,         -- Unix timestamp
}
```

**Note:** The `data.usage` field is deprecated. Use `data.response.usage` instead.

**Example:**
```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatResponseDone",
    callback = function(event)
        local response = event.data.response
        local usage = event.data.response.usage
        print("Response complete: " .. response.content:sub(1, 50) .. "...")
        print("Tokens: input=" .. usage.input_tokens .. ", output=" .. usage.output_tokens)
        print("TTFT: " .. event.data.ttft_ms .. "ms")
    end,
})
```

### AiChatResponseError

Fired when a response fails with an error.

**Location:** `lua/ai-chat/pipeline.lua:155`

**Payload:**
```lua
{
    error = AiChatError,  -- Error object with code, message, and retryable flag
}
```

**Error object structure:**
```lua
{
    code = string,              -- Error classification (e.g., "auth", "network", "model_not_found")
    message = string,           -- Human-readable error message
    retryable = boolean,        -- Whether the error is retryable (optional, defaults to false)
}
```

**Common error codes:**
- `"auth"` — Authentication failed (invalid API key, bearer token, etc.)
- `"network"` — Network error (connection refused, timeout, etc.) — retryable
- `"model_not_found"` — Model not available on the provider
- `"server"` — Server error from the provider
- `"rate_limit"` — Rate limit exceeded — retryable

**Example:**
```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatResponseError",
    callback = function(event)
        local error = event.data.error
        print("Error: " .. error.code .. " - " .. error.message)
        if error.retryable then
            print("This error is retryable")
        end
    end,
})
```

## Payload Contracts

Once documented, event names and payload shapes are frozen. Breaking changes to event payloads will only occur in major version bumps and will be announced in the changelog.

**Stability guarantees:**
- Event names are stable and will not change
- Payload fields are stable and will not be removed
- New fields may be added to payloads in minor versions
- Consumers should ignore unknown fields for forward compatibility

## Usage Patterns

### Listen to all AI events

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AiChat*",
    callback = function(event)
        print("AI event: " .. event.match)
    end,
})
```

### Integrate with status line

```lua
local ai_status = ""

vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatResponseStart",
    callback = function()
        ai_status = "⏳ Thinking..."
    end,
})

vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatResponseDone",
    callback = function()
        ai_status = "✓ Done"
    end,
})

vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatResponseError",
    callback = function()
        ai_status = "✗ Error"
    end,
})

-- In your statusline:
-- return ai_status
```

### Track conversation state

```lua
local conversation_open = false

vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatPanelOpened",
    callback = function()
        conversation_open = true
    end,
})

vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatPanelClosed",
    callback = function()
        conversation_open = false
    end,
})

vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatConversationCleared",
    callback = function()
        if conversation_open then
            print("Conversation cleared")
        end
    end,
})
```
