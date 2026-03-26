--- ai-chat.nvim — Buffer lifecycle autocommands
--- Guards against inconsistent state when chat/input windows or buffers
--- are closed externally (`:q`, `<C-w>c`, `:only`, `:bwipeout`).

local M = {}

--- Set up lifecycle autocommands for the chat panel.
--- Registered in a single augroup, cleared on each open() and deleted on close().
---@param ui_state table  Reference to the UI state table from init.lua
---@param get_stream fun(): table  Function to get the stream module
function M.setup(ui_state, get_stream)
    local config = require("ai-chat.config").get()
    local group = vim.api.nvim_create_augroup("ai-chat-lifecycle", { clear = true })

    local function reset_state()
        ui_state.is_open = false
        ui_state.chat_winid = nil
        ui_state.input_winid = nil
        ui_state.chat_bufnr = nil
        ui_state.input_bufnr = nil
        pcall(vim.api.nvim_del_augroup_by_name, "ai-chat-lifecycle")
        pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatPanelClosed" })
    end

    local function cancel_if_active()
        if get_stream().is_active() then
            get_stream().cancel()
        end
    end

    -- Guard: chat window closed externally
    if ui_state.chat_winid then
        vim.api.nvim_create_autocmd("WinClosed", {
            group = group,
            pattern = tostring(ui_state.chat_winid),
            callback = function()
                vim.schedule(function()
                    if not ui_state.is_open then
                        return
                    end
                    cancel_if_active()
                    pcall(require("ai-chat.ui.input").destroy)
                    reset_state()
                end)
            end,
        })
    end

    -- Guard: chat buffer wiped
    if ui_state.chat_bufnr then
        vim.api.nvim_create_autocmd("BufWipeout", {
            group = group,
            buffer = ui_state.chat_bufnr,
            callback = function()
                vim.schedule(function()
                    if not ui_state.is_open then
                        return
                    end
                    cancel_if_active()
                    pcall(require("ai-chat.ui.input").destroy)
                    reset_state()
                end)
            end,
        })
    end

    -- Guard: input buffer wiped externally
    if ui_state.input_bufnr then
        vim.api.nvim_create_autocmd("BufWipeout", {
            group = group,
            buffer = ui_state.input_bufnr,
            callback = function()
                vim.schedule(function()
                    if not ui_state.is_open then
                        return
                    end
                    -- If chat window is still valid, recreate the input
                    if ui_state.chat_winid and vim.api.nvim_win_is_valid(ui_state.chat_winid) then
                        local input = require("ai-chat.ui.input")
                        local result = input.create(ui_state.chat_winid, config.ui.input_height)
                        ui_state.input_bufnr = result.bufnr
                        ui_state.input_winid = result.winid
                    else
                        reset_state()
                    end
                end)
            end,
        })
    end
end

return M
