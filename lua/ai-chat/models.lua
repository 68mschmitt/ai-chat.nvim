--- ai-chat.nvim — Model registry
--- Fetches, caches, and serves model metadata from models.dev.
--- Provides model discovery for all providers (context windows, pricing,
--- display names) without hardcoding model lists.
---
--- Cache: ~/.cache/ai-chat/models.json (refreshed hourly)
--- Source: https://models.dev/api.json

local M = {}

local SOURCE_URL = "https://models.dev/api.json"

--- Provider ID mapping: our provider names -> models.dev provider IDs.
local PROVIDER_MAP = {
    anthropic = "anthropic",
    openai_compat = "openai",
    bedrock = "amazon-bedrock",
    ollama = nil, -- Ollama discovers models locally, not from models.dev
}

--- In-memory cache of the full models.dev data.
---@type table?
local _cache = nil

--- Timestamp of last successful fetch (os.time()).
---@type number?
local _last_fetch = nil

--- Refresh interval in seconds (1 hour).
local REFRESH_INTERVAL = 3600

-- ─── Cache paths ─────────────────────────────────────────────────────

--- Get the cache file path.
---@return string
local function cache_path()
    local dir = vim.fn.stdpath("cache") .. "/ai-chat"
    vim.fn.mkdir(dir, "p")
    return dir .. "/models.json"
end

-- ─── Fetch / Load ────────────────────────────────────────────────────

--- Load models from the local disk cache.
---@return table?
local function load_from_disk()
    local path = cache_path()
    if vim.fn.filereadable(path) ~= 1 then
        return nil
    end

    local lines = vim.fn.readfile(path)
    if #lines == 0 then
        return nil
    end

    local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not ok or type(data) ~= "table" then
        return nil
    end

    return data
end

--- Save models data to the local disk cache.
---@param data table
local function save_to_disk(data)
    local path = cache_path()
    local ok, json = pcall(vim.json.encode, data)
    if ok then
        vim.fn.writefile({ json }, path)
    end
end

--- Fetch models from models.dev asynchronously.
--- Updates the in-memory cache and saves to disk on success.
---@param callback? fun(ok: boolean)
function M.fetch(callback)
    vim.system({
        "curl",
        "-s",
        "--connect-timeout",
        "5",
        "--max-time",
        "15",
        SOURCE_URL,
    }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 or not result.stdout or result.stdout == "" then
                if callback then
                    callback(false)
                end
                return
            end

            local ok, data = pcall(vim.json.decode, result.stdout)
            if not ok or type(data) ~= "table" then
                if callback then
                    callback(false)
                end
                return
            end

            _cache = data
            _last_fetch = os.time()
            save_to_disk(data)

            if callback then
                callback(true)
            end
        end)
    end)
end

--- Ensure the models data is loaded (from memory, disk, or remote).
--- Returns immediately with whatever is available; kicks off an async
--- fetch in the background if the data is stale or missing.
---@return table?  The full models.dev data, or nil if not yet available
function M.ensure()
    -- Already in memory and fresh
    if _cache and _last_fetch and (os.time() - _last_fetch) < REFRESH_INTERVAL then
        return _cache
    end

    -- Try disk cache
    if not _cache then
        _cache = load_from_disk()
        if _cache then
            _last_fetch = os.time()
        end
    end

    -- Kick off background refresh (non-blocking)
    M.fetch()

    return _cache
end

-- ─── Model Queries ───────────────────────────────────────────────────

--- Get all models for a provider.
---@param provider_name string  Our internal provider name (e.g., "anthropic", "bedrock")
---@return table[]  List of model entries from models.dev
function M.get_models(provider_name)
    local data = M.ensure()
    if not data then
        return {}
    end

    local dev_id = PROVIDER_MAP[provider_name]
    if not dev_id then
        return {}
    end

    local provider_data = data[dev_id]
    if not provider_data or not provider_data.models then
        return {}
    end

    -- Convert the models object to a sorted list
    local models = {}
    for _, model in pairs(provider_data.models) do
        table.insert(models, model)
    end

    -- Sort by name
    table.sort(models, function(a, b)
        return (a.name or a.id) < (b.name or b.id)
    end)

    return models
end

--- Get model IDs for a provider (just the ID strings, for simple pickers).
---@param provider_name string
---@return string[]
function M.get_model_ids(provider_name)
    local models = M.get_models(provider_name)
    local ids = {}
    for _, model in ipairs(models) do
        table.insert(ids, model.id)
    end
    return ids
end

--- Get formatted model entries for use in vim.ui.select.
--- Returns items with display text and the raw model ID.
---@param provider_name string
---@return { display: string, id: string, model: table }[]
function M.get_picker_items(provider_name)
    local models = M.get_models(provider_name)
    local items = {}
    for _, model in ipairs(models) do
        local display = model.name or model.id
        -- Add context window and cost info
        local meta = {}
        if model.limit and model.limit.context then
            local ctx_k = math.floor(model.limit.context / 1000)
            table.insert(meta, ctx_k .. "K ctx")
        end
        if model.cost and model.cost.input then
            table.insert(meta, "$" .. model.cost.input .. "/$" .. model.cost.output .. " per 1M")
        end
        if #meta > 0 then
            display = display .. "  (" .. table.concat(meta, ", ") .. ")"
        end
        table.insert(items, {
            display = display,
            id = model.id,
            model = model,
        })
    end
    return items
end

--- Look up a specific model by ID.
---@param provider_name string  Our provider name
---@param model_id string       The model ID
---@return table?  The model entry, or nil
function M.get_model(provider_name, model_id)
    local models = M.get_models(provider_name)
    for _, model in ipairs(models) do
        if model.id == model_id then
            return model
        end
    end
    return nil
end

--- Get the context window for a model from models.dev data.
---@param provider_name string
---@param model_id string
---@return number?  Context window in tokens, or nil if unknown
function M.get_context_window(provider_name, model_id)
    local model = M.get_model(provider_name, model_id)
    if model and model.limit and model.limit.context then
        return model.limit.context
    end
    return nil
end

--- Get pricing for a model from models.dev data.
---@param provider_name string
---@param model_id string
---@return { input: number, output: number }?  Cost per 1M tokens, or nil
function M.get_pricing(provider_name, model_id)
    local model = M.get_model(provider_name, model_id)
    if model and model.cost then
        return {
            input = model.cost.input or 0,
            output = model.cost.output or 0,
        }
    end
    return nil
end

--- Initialize the models registry. Called during setup().
--- Loads from disk cache and kicks off a background refresh.
function M.init()
    M.ensure()
end

return M
