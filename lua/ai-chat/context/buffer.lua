--- ai-chat.nvim — @buffer context collector
--- Collects the entire content of the current (code) buffer.

local M = {}

--- Collect the current buffer content.
---@param args? string  Unused for @buffer
---@return AiChatContext?
function M.collect(args)
    -- Find the "code" buffer (not the chat or input buffer)
    local bufnr = M._find_code_buffer()
    if not bufnr then
        return nil
    end

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content = table.concat(lines, "\n")
    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
    local filetype = vim.bo[bufnr].filetype
    local token_estimate = require("ai-chat.util.tokens").estimate(content)

    return {
        type = "buffer",
        content = content,
        source = filename .. " (" .. #lines .. " lines)",
        token_estimate = token_estimate,
        metadata = {
            bufnr = bufnr,
            filename = filename,
            filetype = filetype,
            line_count = #lines,
        },
    }
end

--- Find the most relevant code buffer (not chat/input buffers).
---@return number?
function M._find_code_buffer()
    -- Try alternate buffer first
    local alt = vim.fn.bufnr("#")
    if alt > 0 and vim.api.nvim_buf_is_valid(alt) and vim.bo[alt].buftype == "" then
        return alt
    end

    -- Fall back to current buffer if it's a code buffer
    local cur = vim.api.nvim_get_current_buf()
    if vim.bo[cur].buftype == "" then
        return cur
    end

    -- Search for any loaded code buffer
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
            return buf
        end
    end

    return nil
end

return M
