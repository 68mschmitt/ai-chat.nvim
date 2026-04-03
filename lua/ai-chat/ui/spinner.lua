--- ai-chat.nvim — Spinner
--- Braille animation displayed during response streaming.
--- Shows spinner in the winbar of the chat window.

local M = {}

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local state = {
    timer = nil,
    frame_index = 1,
    saved_winbar = nil,
    active_winid = nil,
}

--- Start the spinner animation.
---@param winid number  Window to show spinner in (via winbar update)
function M.start(winid)
    if state.timer then
        return
    end -- Already running
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    state.active_winid = winid
    state.saved_winbar = vim.wo[winid].winbar
    state.frame_index = 1

    local uv = vim.uv or vim.loop
    state.timer = uv.new_timer()
    state.timer:start(
        0,
        80,
        vim.schedule_wrap(function()
            if not state.active_winid or not vim.api.nvim_win_is_valid(state.active_winid) then
                M.stop()
                return
            end

            state.frame_index = (state.frame_index % #frames) + 1
            local spinner = frames[state.frame_index]
            local base = state.saved_winbar or " ai-chat"
            vim.wo[state.active_winid].winbar = base .. " | " .. spinner .. " generating..."
        end)
    )
end

--- Stop the spinner animation and restore the winbar.
function M.stop()
    if state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
    end
    -- Restore the original winbar
    if state.active_winid and vim.api.nvim_win_is_valid(state.active_winid) and state.saved_winbar then
        vim.wo[state.active_winid].winbar = state.saved_winbar
    end
    state.active_winid = nil
    state.saved_winbar = nil
end

return M
