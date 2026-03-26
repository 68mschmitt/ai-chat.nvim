--- ai-chat.nvim — Conversation persistence
--- Manages saving and loading conversations to/from disk.

local M = {}

local store = require("ai-chat.history.store")

local config = {}

--- Initialize history with config.
---@param history_config table  The history section of AiChatConfig
function M.init(history_config)
    config = history_config
    local path = require("ai-chat.config").history_path({ history = config })
    store.init(path, config.max_conversations)
end

--- Save a conversation to disk.
---@param conversation AiChatConversation
---@param name? string  Optional human-readable name
function M.save(conversation, name)
    if not config.enabled then return end

    local entry = {
        id = conversation.id,
        name = name or M._generate_name(conversation),
        provider = conversation.provider,
        model = conversation.model,
        created_at = conversation.created_at,
        updated_at = os.time(),
        message_count = #conversation.messages,
        messages = conversation.messages,
    }

    store.write(entry)
end

--- Load a conversation by ID.
---@param id string
---@return AiChatConversation?
function M.load(id)
    return store.read(id)
end

--- Browse saved conversations. Calls the callback with the selected conversation.
---@param callback fun(conversation: AiChatConversation?)
function M.browse(callback)
    local entries = store.list()

    if #entries == 0 then
        vim.notify("[ai-chat] No saved conversations", vim.log.levels.INFO)
        callback(nil)
        return
    end

    -- Try telescope if available
    local has_telescope, _ = pcall(require, "telescope")
    if has_telescope then
        M._browse_telescope(entries, callback)
        return
    end

    -- Fallback to vim.ui.select
    local items = {}
    for _, entry in ipairs(entries) do
        table.insert(items, string.format(
            "%s — %s (%d messages, %s)",
            entry.name or "untitled",
            entry.model or "unknown",
            entry.message_count or 0,
            os.date("%Y-%m-%d %H:%M", entry.updated_at or 0)
        ))
    end

    vim.ui.select(items, { prompt = "Load conversation:" }, function(_, idx)
        if idx then
            local conv = M.load(entries[idx].id)
            callback(conv)
        else
            callback(nil)
        end
    end)
end

--- Generate a name from the first user message.
---@param conversation AiChatConversation
---@return string
function M._generate_name(conversation)
    for _, msg in ipairs(conversation.messages) do
        if msg.role == "user" then
            local text = msg.content:gsub("@%S+%s*", ""):sub(1, 60)
            return vim.trim(text)
        end
    end
    return "untitled"
end

--- Browse conversations with telescope (if available).
---@param entries table[]
---@param callback fun(conversation: AiChatConversation?)
function M._browse_telescope(entries, callback)
    -- Telescope integration would go here in v0.3
    -- For now, fall through to vim.ui.select
    M.browse(callback)
end

return M
