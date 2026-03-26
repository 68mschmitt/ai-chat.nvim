--- ai-chat.nvim — Chat split window management
--- Creates and manages the vertical split containing the chat buffer.

local M = {}

local state = {
    bufnr = nil,
    winid = nil,
}

--- Create the chat split and buffer.
---@param width number  Column width for the split
---@param position "right"|"left"
---@return { bufnr: number, winid: number }
function M.create(width, position)
    -- Create scratch buffer for chat content
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "ai-chat://chat")

    -- Buffer options
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "aichat"
    vim.bo[bufnr].modifiable = false

    -- Create the vertical split
    local split_cmd = position == "left" and "topleft" or "botright"
    vim.cmd(split_cmd .. " " .. width .. "vsplit")
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)

    -- Window options
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
    vim.wo[winid].foldcolumn = "0"
    vim.wo[winid].wrap = true
    vim.wo[winid].linebreak = true
    vim.wo[winid].cursorline = false
    vim.wo[winid].spell = false
    vim.wo[winid].list = false
    vim.wo[winid].conceallevel = 2
    vim.wo[winid].concealcursor = "nc"

    -- Set up buffer-local keymaps
    M._setup_keymaps(bufnr)

    state.bufnr = bufnr
    state.winid = winid

    -- Return focus to the previous window
    vim.cmd("wincmd p")

    return { bufnr = bufnr, winid = winid }
end

--- Destroy the chat split.
function M.destroy()
    if state.winid and vim.api.nvim_win_is_valid(state.winid) then
        vim.api.nvim_win_close(state.winid, true)
    end
    if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
        vim.api.nvim_buf_delete(state.bufnr, { force = true })
    end
    state.bufnr = nil
    state.winid = nil
end

--- Update the winbar to show current status.
---@param winid number
---@param conversation AiChatConversation
function M.update_winbar(winid, conversation)
    if not winid or not vim.api.nvim_win_is_valid(winid) then return end

    local parts = { " ai-chat" }

    if conversation then
        table.insert(parts, conversation.provider .. "/" .. conversation.model)
        table.insert(parts, "msgs: " .. #conversation.messages)
    end

    vim.wo[winid].winbar = table.concat(parts, " │ ")
end

--- Set up buffer-local keymaps for the chat buffer.
---@param bufnr number
function M._setup_keymaps(bufnr)
    local map = function(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = "[ai-chat] " .. desc })
    end

    -- These use the config keys, but we hardcode defaults here as the
    -- config-driven mapping happens in init.lua. These are the buffer-local
    -- actions that only make sense in the chat buffer.
    map("n", "q", function() require("ai-chat").close() end, "Close panel")
    map("n", "<C-c>", function() require("ai-chat").cancel() end, "Cancel generation")
    map("n", "]]", function() M._jump_message(bufnr, "next") end, "Next message")
    map("n", "[[", function() M._jump_message(bufnr, "prev") end, "Previous message")
    map("n", "]c", function() M._jump_code_block(bufnr, "next") end, "Next code block")
    map("n", "[c", function() M._jump_code_block(bufnr, "prev") end, "Previous code block")
    map("n", "gY", function() M._yank_code_block(bufnr) end, "Yank code block")
    map("n", "ga", function() M._apply_code_block(bufnr) end, "Apply code block")
    map("n", "gO", function() M._open_code_block(bufnr) end, "Open code block in split")
    map("n", "i", function()
        -- Focus input area instead of entering insert mode
        local ai_chat = require("ai-chat")
        local config = ai_chat.get_config()
        -- The input window is managed by ui.input
        require("ai-chat.ui.input").focus()
    end, "Focus input")
end

--- Jump to next/previous message header (## You / ## Assistant).
---@param bufnr number
---@param direction "next"|"prev"
function M._jump_message(bufnr, direction)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(state.winid)
    local current_line = cursor[1]

    local targets = {}
    for i, line in ipairs(lines) do
        if line:match("^## You") or line:match("^## Assistant") then
            table.insert(targets, i)
        end
    end

    if #targets == 0 then return end

    if direction == "next" then
        for _, target in ipairs(targets) do
            if target > current_line then
                vim.api.nvim_win_set_cursor(state.winid, { target, 0 })
                return
            end
        end
    else
        for i = #targets, 1, -1 do
            if targets[i] < current_line then
                vim.api.nvim_win_set_cursor(state.winid, { targets[i], 0 })
                return
            end
        end
    end
end

--- Jump to next/previous code block.
---@param bufnr number
---@param direction "next"|"prev"
function M._jump_code_block(bufnr, direction)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(state.winid)
    local current_line = cursor[1]

    local fences = {}
    for i, line in ipairs(lines) do
        if line:match("^```%w") then
            table.insert(fences, i + 1) -- Position cursor on first line of code
        end
    end

    if #fences == 0 then return end

    if direction == "next" then
        for _, target in ipairs(fences) do
            if target > current_line then
                vim.api.nvim_win_set_cursor(state.winid, { target, 0 })
                return
            end
        end
    else
        for i = #fences, 1, -1 do
            if fences[i] < current_line then
                vim.api.nvim_win_set_cursor(state.winid, { fences[i], 0 })
                return
            end
        end
    end
end

--- Yank the code block under cursor to the clipboard.
---@param bufnr number
function M._yank_code_block(bufnr)
    local block = require("ai-chat.ui.render").get_code_block_at_cursor(bufnr, state.winid)
    if block then
        vim.fn.setreg("+", block.content)
        vim.notify("[ai-chat] Code block yanked to clipboard", vim.log.levels.INFO)
    else
        vim.notify("[ai-chat] No code block under cursor", vim.log.levels.WARN)
    end
end

--- Apply the code block under cursor via diff.
---@param bufnr number
function M._apply_code_block(bufnr)
    local block = require("ai-chat.ui.render").get_code_block_at_cursor(bufnr, state.winid)
    if block then
        require("ai-chat.ui.diff").apply(block)
    else
        vim.notify("[ai-chat] No code block under cursor", vim.log.levels.WARN)
    end
end

--- Open the code block under cursor in a new split buffer.
---@param bufnr number
function M._open_code_block(bufnr)
    local block = require("ai-chat.ui.render").get_code_block_at_cursor(bufnr, state.winid)
    if block then
        -- Create a new scratch buffer with the code
        local new_buf = vim.api.nvim_create_buf(false, true)
        local lines = vim.split(block.content, "\n")
        vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, lines)
        if block.language then
            vim.bo[new_buf].filetype = block.language
        end
        -- Open in a split to the left of the chat
        vim.cmd("wincmd p")
        vim.cmd("split")
        vim.api.nvim_win_set_buf(0, new_buf)
    else
        vim.notify("[ai-chat] No code block under cursor", vim.log.levels.WARN)
    end
end

return M
