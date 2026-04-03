--- ai-chat.nvim — File-based JSON storage for conversations
--- Stores each conversation as a separate JSON file.
--- Directory: {storage_path}/{conversation_id}.json
--- Maintains an index.json file for O(1) list() operations.

local M = {}

local state = {
    storage_path = "",
    max_conversations = 100,
}

--- Initialize the store.
---@param path string  Directory to store conversations
---@param max number   Maximum number of conversations to keep
function M.init(path, max)
    state.storage_path = path
    state.max_conversations = max

    -- Ensure directory exists
    vim.fn.mkdir(path, "p")
end

--- Load index from disk.
---@return table?
local function load_index()
    local path = state.storage_path .. "/index.json"
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

--- Write index to disk atomically.
---@param entries table
local function write_index_atomic(entries)
    local index_path = state.storage_path .. "/index.json"
    local tmp = index_path .. ".tmp"
    local json = vim.json.encode(entries)
    vim.fn.writefile({ json }, tmp)
    vim.fn.rename(tmp, index_path)
end

--- Extract metadata from a conversation entry.
---@param data table
---@return table
local function extract_metadata(data)
    return {
        id = data.id,
        name = data.name,
        provider = data.provider,
        model = data.model,
        created_at = data.created_at,
        updated_at = data.updated_at,
        message_count = data.message_count,
    }
end

--- Write a conversation entry to disk.
---@param entry table  Conversation data with an `id` field
function M.write(entry)
    local filepath = state.storage_path .. "/" .. entry.id .. ".json"
    local json = vim.json.encode(entry)
    vim.fn.writefile({ json }, filepath)

    -- Update index
    local index = load_index() or {}
    local found = false
    for i, idx_entry in ipairs(index) do
        if idx_entry.id == entry.id then
            index[i] = extract_metadata(entry)
            found = true
            break
        end
    end
    if not found then
        table.insert(index, extract_metadata(entry))
    end
    write_index_atomic(index)

    -- Prune old conversations if over limit
    M._prune(index)
end

--- Read a conversation by ID.
---@param id string
---@return AiChatConversation?
function M.read(id)
    local filepath = state.storage_path .. "/" .. id .. ".json"
    if vim.fn.filereadable(filepath) ~= 1 then
        return nil
    end

    local lines = vim.fn.readfile(filepath)
    if #lines == 0 then
        return nil
    end

    local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not ok then
        return nil
    end

    return data
end

--- List all stored conversations (metadata only, no messages).
--- Sorted by updated_at descending (newest first).
---@return table[]
function M.list()
    local index = load_index()

    -- If index doesn't exist or is invalid, rebuild it
    if not index then
        M._rebuild_index()
        index = load_index()
    end

    if not index then
        return {}
    end

    -- Sort newest first
    table.sort(index, function(a, b)
        return (a.updated_at or 0) > (b.updated_at or 0)
    end)

    return index
end

--- Delete a conversation by ID.
---@param id string
function M.delete(id)
    local filepath = state.storage_path .. "/" .. id .. ".json"
    if vim.fn.filereadable(filepath) == 1 then
        vim.fn.delete(filepath)
    end

    -- Remove from index
    local index = load_index() or {}
    for i, entry in ipairs(index) do
        if entry.id == id then
            table.remove(index, i)
            break
        end
    end
    write_index_atomic(index)
end

--- Prune old conversations if over the limit.
---@param index table?  Optional pre-loaded index to avoid re-reading
function M._prune(index)
    if not index then
        index = load_index() or {}
    end

    if #index <= state.max_conversations then
        return
    end

    -- Sort to identify oldest entries
    table.sort(index, function(a, b)
        return (a.updated_at or 0) > (b.updated_at or 0)
    end)

    -- Delete oldest entries beyond the limit
    for i = state.max_conversations + 1, #index do
        M.delete(index[i].id)
    end
end

--- Rebuild index from all conversation files on disk.
--- This is the recovery path when index.json is missing or corrupt.
function M._rebuild_index()
    local entries = {}

    local files = vim.fn.glob(state.storage_path .. "/*.json", false, true)
    for _, filepath in ipairs(files) do
        -- Skip index.json itself
        if not filepath:match("/index%.json$") then
            local lines = vim.fn.readfile(filepath)
            if #lines > 0 then
                local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
                if ok and data and data.id then
                    table.insert(entries, extract_metadata(data))
                end
            end
        end
    end

    write_index_atomic(entries)
end

return M
