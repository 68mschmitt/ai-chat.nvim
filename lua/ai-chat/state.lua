--- ai-chat.nvim — Persisted user state
--- Saves/restores user preferences that survive across neovim sessions.
--- Currently tracks: last used provider and model.
---
--- File: {stdpath("data")}/ai-chat/state.json

local M = {}

---@type { last_provider?: string, last_model?: string }
local _state = {}

--- Override path for testing. nil = use default stdpath.
---@type string?
local _custom_dir = nil

--- Get the state directory.
---@return string
local function state_dir()
    return _custom_dir or (vim.fn.stdpath("data") .. "/ai-chat")
end

--- Get the state file path.
---@return string
local function state_path()
    local dir = state_dir()
    vim.fn.mkdir(dir, "p")
    return dir .. "/state.json"
end

--- Initialize with a custom directory (for testing).
--- If not called, uses the default stdpath("data")/ai-chat.
---@param dir? string
function M.init(dir)
    _custom_dir = dir
end

--- Load persisted state from disk.
--- Returns the loaded state table (empty table if nothing on disk).
---@return { last_provider?: string, last_model?: string }
function M.load()
    local path = state_path()
    if vim.fn.filereadable(path) ~= 1 then
        _state = {}
        return _state
    end

    local lines = vim.fn.readfile(path)
    if #lines == 0 then
        _state = {}
        return _state
    end

    local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
    if ok and type(data) == "table" then
        _state = data
    else
        _state = {}
    end

    return _state
end

--- Write current state to disk.
function M.save()
    local path = state_path()
    local ok, json = pcall(vim.json.encode, _state)
    if ok then
        vim.fn.writefile({ json }, path)
    end
end

--- Persist the last used provider and model.
---@param provider string
---@param model string
function M.set_last_model(provider, model)
    _state.last_provider = provider
    _state.last_model = model
    M.save()
end

--- Get the last used provider, or nil if never set.
---@return string?
function M.get_last_provider()
    return _state.last_provider
end

--- Get the last used model, or nil if never set.
---@return string?
function M.get_last_model()
    return _state.last_model
end

--- Reset in-memory state and custom path (for testing).
function M._reset()
    _state = {}
    _custom_dir = nil
end

return M
