--- ai-chat.nvim — Command router
--- Dispatches slash commands from the input area.

local M = {}

local slash = require("ai-chat.commands.slash")

--- Handle a slash command.
---@param text string  The full input text (starts with "/")
---@param state table  Plugin state (from init.lua)
function M.handle(text, state)
    local cmd, args = text:match("^/(%S+)%s*(.*)")
    if not cmd then
        vim.notify("[ai-chat] Invalid command: " .. text, vim.log.levels.WARN)
        return
    end

    args = vim.trim(args)

    local handler = slash.commands[cmd]
    if handler then
        handler(args, state)
    else
        vim.notify("[ai-chat] Unknown command: /" .. cmd .. ". Type /help for available commands.", vim.log.levels.WARN)
    end
end

return M
