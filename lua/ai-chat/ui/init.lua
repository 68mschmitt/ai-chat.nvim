--- ai-chat.nvim — UI coordinator
--- Manages the chat split, input area, and delegates rendering.

local M = {}

local chat = require("ai-chat.ui.chat")
local input = require("ai-chat.ui.input")

--- Open the chat panel. Creates the split, chat buffer, and input area.
---@param ui_config table  The ui section of AiChatConfig
---@param conversation AiChatConversation  Current conversation to render
---@return { chat_bufnr: number, chat_winid: number, input_bufnr: number, input_winid: number }
function M.open(ui_config, conversation)
    -- Calculate width
    local editor_width = vim.o.columns
    local width = math.floor(editor_width * ui_config.width)
    width = math.max(width, ui_config.min_width)
    width = math.min(width, ui_config.max_width)

    -- Create the vertical split
    local chat_result = chat.create(width, ui_config.position)

    -- Create the input area at the bottom of the chat split
    local input_result = input.create(chat_result.winid, ui_config.input_height)

    -- Render existing conversation if any
    if conversation and #conversation.messages > 0 then
        local render = require("ai-chat.ui.render")
        render.render_conversation(chat_result.bufnr, conversation)
    end

    -- Update winbar
    if ui_config.show_winbar then
        chat.update_winbar(chat_result.winid, conversation)
    end

    return {
        chat_bufnr = chat_result.bufnr,
        chat_winid = chat_result.winid,
        input_bufnr = input_result.bufnr,
        input_winid = input_result.winid,
    }
end

--- Close the chat panel. Cleans up windows and buffers.
function M.close()
    input.destroy()
    chat.destroy()
end

return M
