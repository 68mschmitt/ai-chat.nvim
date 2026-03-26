--- ai-chat.nvim — Anthropic provider (stub)
--- Direct Anthropic API access. Supports Claude models and extended thinking.
--- Endpoint: https://api.anthropic.com/v1/messages (SSE streaming)

local M = {}

M.name = "anthropic"

---@param config table
---@return boolean ok
---@return string? error_message
function M.validate(config)
    local api_key = (config and config.api_key) or vim.env.ANTHROPIC_API_KEY
    if not api_key or api_key == "" then
        return false, "No Anthropic API key. Set ANTHROPIC_API_KEY env var."
    end
    return true
end

---@param config table
---@param callback fun(models: string[])
function M.list_models(config, callback)
    -- Anthropic doesn't have a models list endpoint; return known models
    callback({
        "claude-sonnet-4-20250514",
        "claude-opus-4-20250514",
        "claude-3-5-haiku-20241022",
    })
end

--- Send a chat request with streaming.
---@param messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param callbacks AiChatCallbacks
---@return CancelFn
function M.chat(messages, opts, callbacks)
    -- TODO: Implement in v0.2
    -- - Build Anthropic messages format (separate system from messages)
    -- - Stream via SSE (event: content_block_delta)
    -- - Handle thinking mode via extended thinking parameter
    -- - Parse usage from message_delta event
    error("[ai-chat] Anthropic provider not yet implemented (planned for v0.2)")
end

return M
