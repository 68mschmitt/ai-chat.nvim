--- ai-chat.nvim — Spinner
--- Braille animation displayed during response streaming.
--- Shows spinner in the winbar of the chat window.

local M = {}

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local timer = nil
local frame_index = 1
local saved_winbar = nil
local active_winid = nil

--- Start the spinner animation.
---@param winid number  Window to show spinner in (via winbar update)
function M.start(winid)
    if timer then
        return
    end -- Already running
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end

    active_winid = winid
    saved_winbar = vim.wo[winid].winbar
    frame_index = 1

    local uv = vim.uv or vim.loop
    timer = uv.new_timer()
    timer:start(
        0,
        80,
        vim.schedule_wrap(function()
            if not active_winid or not vim.api.nvim_win_is_valid(active_winid) then
                M.stop()
                return
            end

            frame_index = (frame_index % #frames) + 1
            local spinner = frames[frame_index]
            local base = saved_winbar or " ai-chat"
            vim.wo[active_winid].winbar = base .. " | " .. spinner .. " generating..."
        end)
    )
end

--- Stop the spinner animation and restore the winbar.
function M.stop()
    if timer then
        timer:stop()
        timer:close()
        timer = nil
    end
    -- Restore the original winbar
    if active_winid and vim.api.nvim_win_is_valid(active_winid) and saved_winbar then
        vim.wo[active_winid].winbar = saved_winbar
    end
    active_winid = nil
    saved_winbar = nil
end

return M
