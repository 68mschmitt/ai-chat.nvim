--- ai-chat.nvim — Amazon Bedrock provider (stub)
--- Enterprise Claude access via AWS Bedrock.
--- Uses the `aws` CLI for request signing.

local M = {}

M.name = "bedrock"

---@param config table
---@return boolean ok
---@return string? error_message
function M.validate(config)
    -- Check for aws CLI
    if vim.fn.executable("aws") ~= 1 then
        return false, "AWS CLI not found. Install it for Bedrock support."
    end
    if not config.region then
        return false, "Bedrock region not configured."
    end
    return true
end

---@param config table
---@param callback fun(models: string[])
function M.list_models(config, callback)
    -- TODO: Query Bedrock for available models via `aws bedrock list-foundation-models`
    callback({
        "anthropic.claude-sonnet-4-20250514-v1:0",
        "anthropic.claude-opus-4-20250514-v1:0",
        "anthropic.claude-3-5-haiku-20241022-v1:0",
    })
end

--- Send a chat request with streaming.
--- Not yet implemented — returns a graceful error via the callback interface.
---@param messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param callbacks AiChatCallbacks
---@return CancelFn
function M.chat(messages, opts, callbacks)
    vim.schedule(function()
        callbacks.on_error({
            code = "not_implemented",
            message = "Bedrock provider not yet implemented (planned for v0.3). "
                .. "Switch to another provider with /provider anthropic or /provider ollama.",
            retryable = false,
        })
    end)
    return function() end
end

return M
