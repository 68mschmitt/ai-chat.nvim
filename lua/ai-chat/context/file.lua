--- ai-chat.nvim — @file context collector
--- Collects the content of a specified file.

local M = {}

--- Collect file content.
---@param args? string  File path (relative or absolute)
---@return AiChatContext?
function M.collect(args)
    if not args or args == "" then
        return nil
    end

    local path = vim.fn.expand(args)

    -- Check if file exists
    if vim.fn.filereadable(path) ~= 1 then
        vim.notify("[ai-chat] File not found: " .. path, vim.log.levels.WARN)
        return nil
    end

    local lines = vim.fn.readfile(path)
    if #lines == 0 then
        return nil
    end

    local content = table.concat(lines, "\n")
    local filename = vim.fn.fnamemodify(path, ":t")
    local ext = vim.fn.fnamemodify(path, ":e")
    local token_estimate = require("ai-chat.util.tokens").estimate(content)

    return {
        type = "file",
        content = content,
        source = args .. " (" .. #lines .. " lines)",
        token_estimate = token_estimate,
        metadata = {
            path = path,
            filename = filename,
            extension = ext,
            line_count = #lines,
        },
    }
end

return M
