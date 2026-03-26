--- ai-chat.nvim — Input area
--- Manages the editable input buffer at the bottom of the chat split.

local M = {}

local state = {
    bufnr = nil,
    winid = nil,
    history = {},      -- Previous messages for recall
    history_index = 0, -- Current position in history
}

--- Create the input area as a horizontal split within the chat window.
---@param parent_winid number  The chat window to split within
---@param height number  Initial height in lines
---@return { bufnr: number, winid: number }
function M.create(parent_winid, height)
    -- Focus the parent (chat) window
    vim.api.nvim_set_current_win(parent_winid)

    -- Create a horizontal split at the bottom
    vim.cmd("botright " .. height .. "split")
    local winid = vim.api.nvim_get_current_win()

    -- Create scratch buffer for input
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_buf_set_name(bufnr, "ai-chat://input")

    -- Buffer options
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "aichat.input"

    -- Window options
    vim.wo[winid].number = false
    vim.wo[winid].relativenumber = false
    vim.wo[winid].signcolumn = "no"
    vim.wo[winid].foldcolumn = "0"
    vim.wo[winid].wrap = true
    vim.wo[winid].linebreak = true
    vim.wo[winid].cursorline = false
    vim.wo[winid].winfixheight = true

    -- Prompt indicator via extmark
    local ns = vim.api.nvim_create_namespace("ai-chat-input")
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
        virt_text = { { "> ", "AiChatInputPrompt" } },
        virt_text_pos = "inline",
    })

    -- Set up keymaps
    M._setup_keymaps(bufnr)

    state.bufnr = bufnr
    state.winid = winid

    -- Return focus to previous window
    vim.cmd("wincmd p")

    return { bufnr = bufnr, winid = winid }
end

--- Destroy the input area.
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

--- Focus the input area and enter insert mode.
function M.focus()
    if state.winid and vim.api.nvim_win_is_valid(state.winid) then
        vim.api.nvim_set_current_win(state.winid)
        vim.cmd("startinsert!")
    end
end

--- Get the current text from the input buffer.
---@return string?
function M.get_text()
    if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
        return nil
    end
    local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    return text ~= "" and text or nil
end

--- Clear the input buffer.
function M.clear()
    if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
        return
    end
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "" })

    -- Re-add prompt extmark
    local ns = vim.api.nvim_create_namespace("ai-chat-input")
    vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(state.bufnr, ns, 0, 0, {
        virt_text = { { "> ", "AiChatInputPrompt" } },
        virt_text_pos = "inline",
    })
end

--- Set up buffer-local keymaps for the input area.
---@param bufnr number
function M._setup_keymaps(bufnr)
    local map = function(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = "[ai-chat] " .. desc })
    end

    -- Normal mode: Enter sends
    map("n", "<CR>", function()
        M._submit()
    end, "Send message")

    -- Insert mode: Ctrl+Enter sends
    map("i", "<C-CR>", function()
        vim.cmd("stopinsert")
        M._submit()
    end, "Send message")

    -- Cancel
    map({ "n", "i" }, "<C-c>", function()
        require("ai-chat").cancel()
    end, "Cancel generation")

    -- History recall
    map("n", "<Up>", function()
        M._recall("prev")
    end, "Previous message")

    map("n", "<Down>", function()
        M._recall("next")
    end, "Next message")

    -- Close panel on q when input is empty
    map("n", "q", function()
        local text = M.get_text()
        if not text or text == "" then
            require("ai-chat").close()
        else
            -- Normal q behavior (record macro) if there's text
            vim.api.nvim_feedkeys("q", "n", false)
        end
    end, "Close panel (when empty)")
end

--- Submit the current input.
function M._submit()
    local text = M.get_text()
    if not text then return end

    -- Save to history
    table.insert(state.history, text)
    state.history_index = #state.history + 1

    -- Send
    require("ai-chat").send(text)
end

--- Recall previous/next message from history.
---@param direction "prev"|"next"
function M._recall(direction)
    if #state.history == 0 then return end

    -- Only recall if input is empty or already recalling
    local current = M.get_text()
    if current and current ~= "" and state.history_index > #state.history then
        return
    end

    if direction == "prev" then
        state.history_index = math.max(1, state.history_index - 1)
    else
        state.history_index = math.min(#state.history + 1, state.history_index + 1)
    end

    local text = state.history[state.history_index] or ""
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, vim.split(text, "\n"))
end

return M
