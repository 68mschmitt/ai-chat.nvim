--- ai-chat.nvim — File-based JSON storage for conversations
--- Stores each conversation as a separate JSON file.
--- Directory: {storage_path}/{conversation_id}.json

local M = {}

local storage_path = ""
local max_conversations = 100

--- Initialize the store.
---@param path string  Directory to store conversations
---@param max number   Maximum number of conversations to keep
function M.init(path, max)
    storage_path = path
    max_conversations = max

    -- Ensure directory exists
    vim.fn.mkdir(path, "p")
end

--- Write a conversation entry to disk.
---@param entry table  Conversation data with an `id` field
function M.write(entry)
    local filepath = storage_path .. "/" .. entry.id .. ".json"
    local json = vim.json.encode(entry)
    vim.fn.writefile({ json }, filepath)

    -- Prune old conversations if over limit
    M._prune()
end

--- Read a conversation by ID.
---@param id string
---@return AiChatConversation?
function M.read(id)
    local filepath = storage_path .. "/" .. id .. ".json"
    if vim.fn.filereadable(filepath) ~= 1 then
        return nil
    end

    local lines = vim.fn.readfile(filepath)
    if #lines == 0 then return nil end

    local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not ok then return nil end

    return data
end

--- List all stored conversations (metadata only, no messages).
--- Sorted by updated_at descending (newest first).
---@return table[]
function M.list()
    local entries = {}

    local files = vim.fn.glob(storage_path .. "/*.json", false, true)
    for _, filepath in ipairs(files) do
        local lines = vim.fn.readfile(filepath)
        if #lines > 0 then
            local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
            if ok and data then
                table.insert(entries, {
                    id = data.id,
                    name = data.name,
                    provider = data.provider,
                    model = data.model,
                    created_at = data.created_at,
                    updated_at = data.updated_at,
                    message_count = data.message_count,
                })
            end
        end
    end

    -- Sort newest first
    table.sort(entries, function(a, b)
        return (a.updated_at or 0) > (b.updated_at or 0)
    end)

    return entries
end

--- Delete a conversation by ID.
---@param id string
function M.delete(id)
    local filepath = storage_path .. "/" .. id .. ".json"
    if vim.fn.filereadable(filepath) == 1 then
        vim.fn.delete(filepath)
    end
end

--- Prune old conversations if over the limit.
function M._prune()
    local entries = M.list()
    if #entries <= max_conversations then return end

    -- Delete oldest entries beyond the limit
    for i = max_conversations + 1, #entries do
        M.delete(entries[i].id)
    end
end

return M
