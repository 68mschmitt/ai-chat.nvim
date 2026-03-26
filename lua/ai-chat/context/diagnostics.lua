--- ai-chat.nvim — @diagnostics context collector
--- Collects LSP diagnostics for the current buffer.

local M = {}

--- Collect LSP diagnostics.
---@param args? string  Unused
---@return AiChatContext?
function M.collect(args)
    local bufnr = vim.api.nvim_get_current_buf()

    -- Try alternate buffer if current is chat/input
    if vim.bo[bufnr].buftype ~= "" then
        bufnr = vim.fn.bufnr("#")
        if bufnr < 0 or not vim.api.nvim_buf_is_valid(bufnr) then
            return nil
        end
    end

    local diagnostics = vim.diagnostic.get(bufnr)
    if #diagnostics == 0 then return nil end

    local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
    local error_count = 0
    local warning_count = 0
    local lines = {}

    for _, diag in ipairs(diagnostics) do
        local severity = diag.severity
        local prefix = "INFO"
        if severity == vim.diagnostic.severity.ERROR then
            prefix = "ERROR"
            error_count = error_count + 1
        elseif severity == vim.diagnostic.severity.WARN then
            prefix = "WARN"
            warning_count = warning_count + 1
        end

        table.insert(lines, string.format(
            "Line %d: [%s] %s",
            diag.lnum + 1,
            prefix,
            diag.message
        ))
    end

    local content = table.concat(lines, "\n")
    local token_estimate = require("ai-chat.util.tokens").estimate(content)

    return {
        type = "diagnostics",
        content = content,
        source = string.format("%s (%d errors, %d warnings)", filename, error_count, warning_count),
        token_estimate = token_estimate,
        metadata = {
            bufnr = bufnr,
            filename = filename,
            error_count = error_count,
            warning_count = warning_count,
            total = #diagnostics,
        },
    }
end

return M
