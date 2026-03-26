--- ai-chat.nvim — Error classification
--- Defines canonical error categories used by stream.lua for retry decisions.
--- Providers map their errors to these categories. Stream.lua only retries
--- errors classified as "retryable".

local M = {}

--- Error categories.
--- @enum AiChatErrorCategory
M.category = {
    RETRYABLE = "retryable", -- rate_limit, server_error, timeout, transient network
    FATAL = "fatal", -- auth, invalid_request, model_not_found, not_implemented
    UNKNOWN = "unknown", -- unclassified errors (treated as fatal by default)
}

--- Canonical error codes and their categories.
--- @type table<string, AiChatErrorCategory>
local code_categories = {
    -- Retryable
    rate_limit = M.category.RETRYABLE,
    server = M.category.RETRYABLE,
    network = M.category.RETRYABLE,
    timeout = M.category.RETRYABLE,

    -- Fatal
    auth = M.category.FATAL,
    invalid_request = M.category.FATAL,
    model_not_found = M.category.FATAL,
    not_implemented = M.category.FATAL,

    -- Unknown
    unknown = M.category.UNKNOWN,
}

--- Classify an error code into a category.
---@param code string  Error code from a provider
---@return AiChatErrorCategory
function M.classify(code)
    return code_categories[code] or M.category.UNKNOWN
end

--- Returns true if an error should be retried based on its code.
--- Only errors with category RETRYABLE are retried. UNKNOWN and FATAL are not.
---@param err AiChatError
---@return boolean
function M.is_retryable(err)
    if err.retryable ~= nil then
        -- Providers can still explicitly override via the retryable field
        return err.retryable
    end
    return M.classify(err.code) == M.category.RETRYABLE
end

--- Create a standardized error table.
---@param code string        One of the canonical error codes
---@param message string     Human-readable error message
---@param opts? { retry_after?: number, retryable?: boolean }
---@return AiChatError
function M.new(code, message, opts)
    opts = opts or {}
    return {
        code = code,
        message = message,
        retryable = opts.retryable, -- nil = use classify(), true/false = explicit override
        retry_after = opts.retry_after,
        category = M.classify(code),
    }
end

return M
