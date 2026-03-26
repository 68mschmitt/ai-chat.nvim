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

    -- Buffer options (set before naming to avoid issues)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "aichat"
    vim.bo[bufnr].modifiable = false

    -- Use pcall for buffer naming since it can fail if name is taken
    pcall(vim.api.nvim_buf_set_name, bufnr, "ai-chat://chat")

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
    vim.wo[winid].winfixwidth = true

    -- Enable treesitter markdown highlighting for code blocks and bold text
    M._setup_treesitter(bufnr, winid)

    -- Set up buffer-local keymaps
    M._setup_keymaps(bufnr)

    state.bufnr = bufnr
    state.winid = winid

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

--- Get the current chat window ID.
---@return number?
function M.get_winid()
    return state.winid
end

--- Get the current chat buffer number.
---@return number?
function M.get_bufnr()
    return state.bufnr
end

--- Update the winbar to show current status.
---@param winid number
---@param conversation AiChatConversation
function M.update_winbar(winid, conversation)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    local parts = { " ai-chat" }

    if conversation then
        table.insert(parts, conversation.provider .. "/" .. conversation.model)

        -- Show thinking mode status
        local ok, config = pcall(function()
            return require("ai-chat.config").get()
        end)
        if ok and config and config.chat and config.chat.thinking then
            local budget = (config.providers.anthropic or {}).thinking_budget or 10000
            table.insert(parts, string.format("thinking: %dK", math.floor(budget / 1000)))
        end

        table.insert(parts, "msgs: " .. #conversation.messages)
    end

    -- Add session cost if applicable
    local cost = require("ai-chat.util.costs").get_session_cost()
    if cost > 0 then
        table.insert(parts, string.format("$%.2f", cost))
    end

    vim.wo[winid].winbar = table.concat(parts, " | ")
end

--- Set up buffer-local keymaps for the chat buffer.
--- Reads bindings from user config; set any key to `false` to disable.
---@param bufnr number
function M._setup_keymaps(bufnr)
    local keys = require("ai-chat.config").get().keys

    local opts = function(desc)
        return { buffer = bufnr, nowait = true, desc = "[ai-chat] " .. desc }
    end

    local function map(key, fn, desc)
        if key then
            vim.keymap.set("n", key, fn, opts(desc))
        end
    end

    map(keys.close, function()
        require("ai-chat").close()
    end, "Close panel")
    map(keys.cancel, function()
        require("ai-chat").cancel()
    end, "Cancel generation")
    map(keys.next_message, function()
        M._jump_message("next")
    end, "Next message")
    map(keys.prev_message, function()
        M._jump_message("prev")
    end, "Previous message")
    map(keys.next_code_block, function()
        M._jump_code_block("next")
    end, "Next code block")
    map(keys.prev_code_block, function()
        M._jump_code_block("prev")
    end, "Previous code block")
    map(keys.yank_code_block, function()
        M._yank_code_block()
    end, "Yank code block")
    map(keys.apply_code_block, function()
        M._apply_code_block()
    end, "Apply code block")
    map(keys.open_code_block, function()
        M._open_code_block()
    end, "Open code block in split")
    map(keys.show_help, function()
        require("ai-chat.commands.slash").commands.help(nil, {})
    end, "Show help")

    -- Always map `i` to focus input (not configurable — fundamental buffer behavior)
    vim.keymap.set("n", "i", function()
        require("ai-chat.ui.input").focus()
    end, opts("Focus input"))
end

--- Jump to next/previous message header (## You / ## Assistant).
---@param direction "next"|"prev"
function M._jump_message(direction)
    if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
        return
    end
    if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(state.winid)
    local current_line = cursor[1]

    local targets = {}
    for i, line in ipairs(lines) do
        if line:match("^## You") or line:match("^## Assistant") then
            table.insert(targets, i)
        end
    end

    if #targets == 0 then
        return
    end

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
---@param direction "next"|"prev"
function M._jump_code_block(direction)
    if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
        return
    end
    if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
        return
    end

    local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
    local cursor = vim.api.nvim_win_get_cursor(state.winid)
    local current_line = cursor[1]

    local fences = {}
    for i, line in ipairs(lines) do
        if line:match("^```%w") then
            table.insert(fences, i + 1) -- Position cursor on first line of code
        end
    end

    if #fences == 0 then
        return
    end

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
function M._yank_code_block()
    if not state.bufnr or not state.winid then
        return
    end
    local block = require("ai-chat.ui.render").get_code_block_at_cursor(state.bufnr, state.winid)
    if block then
        vim.fn.setreg("+", block.content)
        vim.fn.setreg('"', block.content)
        vim.notify("[ai-chat] Code block yanked", vim.log.levels.INFO)
    else
        vim.notify("[ai-chat] No code block under cursor", vim.log.levels.WARN)
    end
end

--- Apply the code block under cursor via diff.
function M._apply_code_block()
    if not state.bufnr or not state.winid then
        return
    end
    local block = require("ai-chat.ui.render").get_code_block_at_cursor(state.bufnr, state.winid)
    if block then
        require("ai-chat.ui.diff").apply(block)
    else
        vim.notify("[ai-chat] No code block under cursor", vim.log.levels.WARN)
    end
end

--- Open the code block under cursor in a new split buffer.
function M._open_code_block()
    if not state.bufnr or not state.winid then
        return
    end
    local block = require("ai-chat.ui.render").get_code_block_at_cursor(state.bufnr, state.winid)
    if block then
        local new_buf = vim.api.nvim_create_buf(false, true)
        local lines = vim.split(block.content, "\n")
        vim.api.nvim_buf_set_lines(new_buf, 0, -1, false, lines)
        if block.language then
            vim.bo[new_buf].filetype = block.language
        end
        vim.bo[new_buf].buftype = "nofile"
        vim.bo[new_buf].bufhidden = "wipe"
        -- Open in the code area
        vim.cmd("wincmd p")
        vim.cmd("split")
        vim.api.nvim_win_set_buf(0, new_buf)
    else
        vim.notify("[ai-chat] No code block under cursor", vim.log.levels.WARN)
    end
end

--- Set up treesitter highlighting for markdown content.
--- Provides language-specific syntax highlighting in fenced code blocks
--- via injection, and enables concealment for bold/italic delimiters.
---@param bufnr number
---@param winid number
function M._setup_treesitter(bufnr, winid)
    local ok = pcall(vim.treesitter.start, bufnr, "markdown")
    if not ok then
        return
    end
    -- Enable concealment so bold/italic delimiters are hidden
    vim.wo[winid].conceallevel = 2
    vim.wo[winid].concealcursor = "n"
end

return M
