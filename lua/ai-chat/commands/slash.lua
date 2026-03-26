--- ai-chat.nvim — Slash command definitions
--- Each command is a function(args, state) where args is the string after the command name.

local M = {}

M.commands = {}

--- /clear — Clear conversation, start fresh.
M.commands.clear = function(args, state)
    require("ai-chat").clear()
    vim.notify("[ai-chat] Conversation cleared", vim.log.levels.INFO)
end

--- /new — Save current conversation and start a new one.
M.commands.new = function(args, state)
    if #state.conversation.messages > 0 then
        require("ai-chat").save()
    end
    require("ai-chat").clear()
    vim.notify("[ai-chat] New conversation started", vim.log.levels.INFO)
end

--- /model [name] — Switch model. Shows picker if no name given.
M.commands.model = function(args, state)
    if args and args ~= "" then
        require("ai-chat").set_model(args)
    else
        require("ai-chat").set_model(nil) -- Opens picker
    end
end

--- /provider [name] — Switch provider. Shows picker if no name given.
M.commands.provider = function(args, state)
    if args and args ~= "" then
        require("ai-chat").set_provider(args)
    else
        require("ai-chat").set_provider(nil) -- Opens picker
    end
end

--- /context — Show current context details.
M.commands.context = function(args, state)
    local context = require("ai-chat.context")
    local available = context.available()

    local lines = { "Available context types:" }
    for _, name in ipairs(available) do
        table.insert(lines, "  @" .. name)
    end
    table.insert(lines, "")
    table.insert(lines, "Usage: type @context_name in your message")
    table.insert(lines, "Example: @buffer How do I fix this?")

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- /save [name] — Save the current conversation.
M.commands.save = function(args, state)
    local name = (args and args ~= "") and args or nil
    require("ai-chat").save(name)
    vim.notify("[ai-chat] Conversation saved", vim.log.levels.INFO)
end

--- /load — Browse and load saved conversations.
M.commands.load = function(args, state)
    require("ai-chat").history()
end

--- /help — List available commands.
M.commands.help = function(args, state)
    local lines = {
        "ai-chat.nvim commands:",
        "",
        "  /clear            Clear conversation",
        "  /new              Save and start new conversation",
        "  /model [name]     Switch model",
        "  /provider [name]  Switch provider",
        "  /context          Show available context types",
        "  /save [name]      Save conversation",
        "  /load             Browse saved conversations",
        "  /help             Show this help",
    }

    -- Render help in the chat buffer if possible
    local ai_chat = require("ai-chat")
    if ai_chat.is_open() then
        local config = ai_chat.get_config()
        local conv = ai_chat.get_conversation()
        -- Just notify for now; could render inline in v0.2
        vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    else
        vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    end
end

--- List all command names (for completion).
---@return string[]
function M.list()
    return vim.tbl_keys(M.commands)
end

return M
