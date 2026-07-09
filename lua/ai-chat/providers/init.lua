--- ai-chat.nvim — Provider registry and dispatcher
--- Routes chat requests to the active provider.
--- Each provider implements the same interface (see API.md).

local M = {}

---@type table<string, AiChatProvider>
local providers = {}

local builtins = { "ollama", "anthropic", "bedrock", "openai_compat", "openai_subscription", "unsloth_studio" }

local function wrap_chat_contract(provider)
    if provider._chat_contract_guarded then
        return provider
    end

    local raw_chat = provider.chat
    provider.chat = function(messages, opts, callbacks)
        local cancelled = false
        local terminal_fired = false
        local guarded = {
            on_chunk = function(text)
                if cancelled or terminal_fired then
                    return
                end
                callbacks.on_chunk(text)
            end,
            on_done = function(response)
                if cancelled or terminal_fired then
                    return
                end
                terminal_fired = true
                callbacks.on_done(response)
            end,
            on_error = function(err)
                if cancelled or terminal_fired then
                    return
                end
                terminal_fired = true
                callbacks.on_error(err)
            end,
        }

        local cancel_fn = raw_chat(messages, opts, guarded) or function() end
        return function()
            cancelled = true
            cancel_fn()
        end
    end
    provider._chat_contract_guarded = true
    return provider
end

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

    providers[name] = wrap_chat_contract(provider)
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
    for _, name in ipairs(builtins) do
        pcall(M.get, name)
    end
    return vim.tbl_keys(providers)
end

--- Return built-in provider names without loading provider modules.
---@return string[]
function M.builtins()
    return vim.deepcopy(builtins)
end

--- Return a human-readable provider name.
---@param name string
---@return string
function M.display_name(name)
    local provider = M.get(name)
    return provider.display_name or provider.name or name
end

--- Return static provider-owned model metadata, if the provider exposes it.
---@param name string
---@return table[]
function M.model_metadata(name)
    local provider = M.get(name)
    if type(provider.model_metadata) == "function" then
        return provider.model_metadata()
    end
    return {}
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

--- Whether a provider supports interactive auth setup.
---@param name string
---@return boolean
function M.supports_auth(name)
    local provider = M.get(name)
    return type(provider.auth_login) == "function"
end

--- List configured providers that support interactive auth setup.
---@param resolved_config table
---@return string[]
function M.auth_providers(resolved_config)
    local names = {}
    for name in pairs(resolved_config.providers or {}) do
        local ok, supported = pcall(M.supports_auth, name)
        if ok and supported then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

--- Return auth setup methods for a provider.
---@param name string
---@param provider_config? table
---@return string[]
function M.auth_methods(name, provider_config)
    local provider = M.get(name)
    if type(provider.auth_methods) == "function" then
        return provider.auth_methods(provider_config)
    end
    return { "default" }
end

--- Start provider-owned interactive auth setup.
---@param name string
---@param provider_config? table
---@param opts? table
---@param callback? fun(ok: boolean, result?: any)
function M.auth_login(name, provider_config, opts, callback)
    local provider = M.get(name)
    if type(provider.auth_login) ~= "function" then
        local msg = ("Provider %s does not support interactive auth setup"):format(name)
        if callback then
            callback(false, msg)
        end
        return
    end
    provider.auth_login(provider_config or {}, opts or {}, callback or function() end)
end

--- Run provider-owned health checks, if available.
---@param name string
---@param provider_config? table
---@param context? table
function M.health(name, provider_config, context)
    local ok, provider = pcall(M.get, name)
    if not ok then
        return
    end
    if type(provider.health) == "function" then
        provider.health(provider_config or {}, context or {})
    end
end

return M
