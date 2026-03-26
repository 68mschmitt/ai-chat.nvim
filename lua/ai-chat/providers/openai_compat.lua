--- ai-chat.nvim — OpenAI-compatible provider (stub)
--- Covers: OpenAI, Azure OpenAI, Groq, Together, LM Studio, etc.
--- Endpoint: configurable (default: https://api.openai.com/v1/chat/completions)
--- Streaming: SSE with data: {"choices":[{"delta":{"content":"..."}}]}

local M = {}

M.name = "openai_compat"

---@param config table
---@return boolean ok
---@return string? error_message
function M.validate(config)
    local api_key = (config and config.api_key) or vim.env.OPENAI_API_KEY
    if not api_key or api_key == "" then
        return false, "No OpenAI API key. Set OPENAI_API_KEY env var."
    end
    if not config.endpoint then
        return false, "No endpoint configured for OpenAI-compatible provider."
    end
    return true
end

---@param config table
---@param callback fun(models: string[])
function M.list_models(config, callback)
    -- TODO: Query /v1/models endpoint
    callback({
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4-turbo",
    })
end

--- Send a chat request with streaming.
---@param messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param callbacks AiChatCallbacks
---@return CancelFn
function M.chat(messages, opts, callbacks)
    -- TODO: Implement in v0.2
    -- - Build OpenAI chat completions request
    -- - Stream via SSE (data: {"choices":[{"delta":{"content":"..."}}]})
    -- - Handle [DONE] sentinel
    -- - Parse usage from final chunk or separate request
    error("[ai-chat] OpenAI-compatible provider not yet implemented (planned for v0.2)")
end

return M
