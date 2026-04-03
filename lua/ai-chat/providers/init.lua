--- ai-chat.nvim — Provider registry and dispatcher
--- Routes chat requests to the active provider.
--- Each provider implements the same interface (see API.md).

local M = {}

---@type table<string, AiChatProvider>
local providers = {}

--- Lazily load and cache a provider module.
---@param name string
---@return AiChatProvider?
function M.get(name)
    if providers[name] then
        return providers[name]
    end

    local ok, provider = pcall(require, "ai-chat.providers." .. name)
    if not ok then
        error("[ai-chat] Failed to load provider '" .. name .. "': " .. provider)
    end

    -- Validate provider shape (api-contracts.md §2)
    local required_fns = { "validate", "preflight", "list_models", "chat" }
    for _, fn_name in ipairs(required_fns) do
        if type(provider[fn_name]) ~= "function" then
            error(("[ai-chat] Provider '%s' missing required function '%s'"):format(name, fn_name))
        end
    end

    providers[name] = provider
    return provider
end

--- Check if a provider exists (without caching it permanently).
---@param name string
---@return boolean
function M.exists(name)
    if providers[name] then
        return true
    end
    local mod_name = "ai-chat.providers." .. name
    -- Try to load via require (respects neovim's rtp, not just package.path)
    local ok = pcall(require, mod_name)
    return ok
end

--- List all available provider names.
---@return string[]
function M.list()
    -- Ensure all built-in providers are loaded
    local builtins = { "ollama", "anthropic", "bedrock", "openai_compat" }
    for _, name in ipairs(builtins) do
        pcall(M.get, name)
    end
    return vim.tbl_keys(providers)
end

--- Validate a provider's configuration.
---@param name string
---@param config table  Provider-specific config
---@return boolean ok
---@return string? error_message
function M.validate(name, config)
    local provider = M.get(name)
    if provider and provider.validate then
        return provider.validate(config)
    end
    return true
end

--- Run a provider's preflight check. Called once per session before first send.
--- Each provider implements its own check (e.g., Ollama: is server running?
--- Anthropic: is API key set? Bedrock: is AWS CLI available?).
---@param name string  Provider name
---@param provider_config? table  Provider-specific config
---@param callback? fun(ok: boolean, err?: string)
function M.preflight(name, provider_config, callback)
    local provider = M.get(name)
    if provider and provider.preflight then
        provider.preflight(provider_config, callback)
    elseif callback then
        callback(true) -- No preflight defined = assume OK
    end
end

return M
