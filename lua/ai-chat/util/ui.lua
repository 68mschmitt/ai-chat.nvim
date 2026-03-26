--- ai-chat.nvim — Shared UI utilities

local M = {}

--- Display lines in a temporary bottom split with `q` to close.
---@param lines string[]  Content lines
---@param opts? { max_height?: number }
function M.show_in_split(lines, opts)
    opts = opts or {}
    local max_height = opts.max_height or 30

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"

    local height = math.min(#lines + 2, max_height)
    vim.cmd("botright " .. height .. "split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
end

return M
