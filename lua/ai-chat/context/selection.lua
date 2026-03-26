--- ai-chat.nvim — @selection context collector
--- Collects the current visual selection.

local M = {}

--- Collect the visual selection content.
---@param args? string  Unused
---@return AiChatContext?
function M.collect(args)
    -- Get the visual selection marks
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")

    if start_pos[2] == 0 and end_pos[2] == 0 then
        return nil -- No visual selection
    end

    local bufnr = start_pos[1] == 0 and vim.api.nvim_get_current_buf() or start_pos[1]
    local start_line = start_pos[2]
    local end_line = end_pos[2]

    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    if #lines == 0 then return nil end

    local content = table.concat(lines, "\n")
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
    local token_estimate = require("ai-chat.util.tokens").estimate(content)

    return {
        type = "selection",
        content = content,
        source = filename .. ":" .. start_line .. "-" .. end_line,
        token_estimate = token_estimate,
        metadata = {
            bufnr = bufnr,
            filename = filename,
            filetype = vim.bo[bufnr].filetype,
            start_line = start_line,
            end_line = end_line,
        },
    }
end

return M
