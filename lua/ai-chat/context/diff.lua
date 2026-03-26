--- ai-chat.nvim — @diff context collector
--- Collects the current git diff (unstaged changes).

local M = {}

--- Collect the git diff.
---@param args? string  Optional: "staged" for staged diff, nil for unstaged
---@return AiChatContext?
function M.collect(args)
    local cmd = { "git", "diff" }
    if args == "staged" then
        table.insert(cmd, "--staged")
    end

    local result = vim.system(cmd, { text = true, timeout = 5000 }):wait()

    if result.code ~= 0 or not result.stdout or result.stdout == "" then
        if result.signal and result.signal ~= 0 then
            vim.notify("[ai-chat] @diff timed out (diff too large?)", vim.log.levels.WARN)
        end
        return nil
    end

    local content = result.stdout
    local token_estimate = require("ai-chat.util.tokens").estimate(content)
    local diff_type = args == "staged" and "staged" or "unstaged"

    return {
        type = "diff",
        content = content,
        source = "git diff (" .. diff_type .. ")",
        token_estimate = token_estimate,
        metadata = {
            diff_type = diff_type,
        },
    }
end

return M
