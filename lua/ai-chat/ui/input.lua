--- ai-chat.nvim — Input area
--- Manages the editable input buffer at the bottom of the chat split.

local M = {}

local state = {
    bufnr = nil,
    winid = nil,
    history = {},
    history_index = 0,
}

local ns_id = vim.api.nvim_create_namespace("ai-chat-input")

--- Create the input area as a horizontal split within the chat window.
---@param parent_winid number  The chat window to split within
---@param height number  Initial height in lines
---@return { bufnr: number, winid: number }
function M.create(parent_winid, height)
    -- Focus the parent (chat) window so the split happens inside it
    vim.api.nvim_set_current_win(parent_winid)

    -- Split below the current window (inside the chat column)
    vim.cmd("belowright " .. height .. "split")
    local winid = vim.api.nvim_get_current_win()

    -- Create scratch buffer for input
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(winid, bufnr)
    pcall(vim.api.nvim_buf_set_name, bufnr, "ai-chat://input")

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
    vim.wo[winid].winbar = " > input"

    -- Set up keymaps
    M._setup_keymaps(bufnr)

    -- Set up winbar placeholder behavior
    M._setup_winbar_autocmds(bufnr, winid)

    state.bufnr = bufnr
    state.winid = winid

    return { bufnr = bufnr, winid = winid }
end

--- Destroy the input area.
function M.destroy()
    if state.bufnr then
        pcall(vim.api.nvim_del_augroup_by_name, "ai-chat-input-" .. state.bufnr)
    end
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
end

--- Set up buffer-local keymaps for the input area.
--- Reads bindings from user config; set any key to `false` to disable.
---@param bufnr number
function M._setup_keymaps(bufnr)
    local keys = require("ai-chat.config").get().keys

    local opts = function(desc)
        return { buffer = bufnr, nowait = true, desc = "[ai-chat] " .. desc }
    end

    -- Normal mode: submit
    if keys.submit_normal then
        vim.keymap.set("n", keys.submit_normal, function()
            M._submit()
        end, opts("Send message"))
    end

    -- Insert mode: submit
    if keys.submit_insert then
        vim.keymap.set("i", keys.submit_insert, function()
            vim.cmd("stopinsert")
            M._submit()
        end, opts("Send message"))
    end

    -- Cancel
    if keys.cancel then
        vim.keymap.set({ "n", "i" }, keys.cancel, function()
            require("ai-chat").cancel()
        end, opts("Cancel generation"))
    end

    -- History recall
    if keys.recall_prev then
        vim.keymap.set("n", keys.recall_prev, function()
            M._recall("prev")
        end, opts("Previous message"))
    end

    if keys.recall_next then
        vim.keymap.set("n", keys.recall_next, function()
            M._recall("next")
        end, opts("Next message"))
    end

    -- Close panel on q when input is empty (uses chat close key)
    if keys.close then
        vim.keymap.set("n", keys.close, function()
            local text = M.get_text()
            if not text then
                require("ai-chat").close()
            end
        end, opts("Close panel (when empty)"))
    end
end

--- Submit the current input.
function M._submit()
    local text = M.get_text()
    if not text then return end

    -- Save to history
    table.insert(state.history, text)
    state.history_index = #state.history + 1

    -- Send via the main module
    require("ai-chat").send(text)
end

--- Recall previous/next message from history.
---@param direction "prev"|"next"
function M._recall(direction)
    if #state.history == 0 then return end
    if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end

    if direction == "prev" then
        state.history_index = math.max(1, state.history_index - 1)
    else
        state.history_index = math.min(#state.history + 1, state.history_index + 1)
    end

    local text = state.history[state.history_index] or ""
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, vim.split(text, "\n"))
end

--- Set up autocmds for winbar placeholder behavior.
--- Clears the winbar when the input window is focused, and restores
--- " > input" when leaving if the buffer is empty.
---@param bufnr number
---@param winid number
function M._setup_winbar_autocmds(bufnr, winid)
    local group = vim.api.nvim_create_augroup("ai-chat-input-" .. bufnr, { clear = true })

    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
        group = group,
        buffer = bufnr,
        callback = function()
            if vim.api.nvim_win_is_valid(winid) then
                vim.wo[winid].winbar = ""
            end
        end,
    })

    vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
        group = group,
        buffer = bufnr,
        callback = function()
            if vim.api.nvim_win_is_valid(winid) then
                if not M.get_text() then
                    vim.wo[winid].winbar = " > input"
                end
            end
        end,
    })
end

return M
