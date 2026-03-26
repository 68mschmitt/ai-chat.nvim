--- ai-chat.nvim — Spinner
--- Braille animation displayed during response streaming.

local M = {}

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local timer = nil
local frame_index = 1

--- Start the spinner animation.
---@param winid number  Window to show spinner in (via winbar update)
function M.start(winid)
    if timer then return end -- Already running

    frame_index = 1
    timer = vim.loop.new_timer()
    timer:start(0, 80, vim.schedule_wrap(function()
        if not winid or not vim.api.nvim_win_is_valid(winid) then
            M.stop()
            return
        end

        frame_index = (frame_index % #frames) + 1
        local spinner = frames[frame_index]

        -- Update winbar with spinner
        local current_winbar = vim.wo[winid].winbar or ""
        -- Replace any existing spinner or add one
        local updated = current_winbar:gsub("[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] generating%.%.%.", spinner .. " generating...")
        if updated == current_winbar then
            -- No existing spinner found, append it
            vim.wo[winid].winbar = current_winbar .. " │ " .. spinner .. " generating..."
        else
            vim.wo[winid].winbar = updated
        end
    end))
end

--- Stop the spinner animation.
function M.stop()
    if timer then
        timer:stop()
        timer:close()
        timer = nil
    end
end

return M
