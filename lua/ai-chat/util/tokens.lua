--- ai-chat.nvim — Approximate token counting
--- Uses a simple heuristic: word_count * 1.33
--- This is intentionally imprecise. For cost display, ~10% error is acceptable.
--- We avoid tiktoken or any external dependency.

local M = {}

--- Estimate token count for a string.
---@param text string
---@return number
function M.estimate(text)
    if not text or text == "" then
        return 0
    end

    -- Count words (sequences of non-whitespace)
    local word_count = 0
    for _ in text:gmatch("%S+") do
        word_count = word_count + 1
    end

    -- Heuristic: ~1.33 tokens per word for English text / code
    -- This tends to undercount slightly for code (more symbols = more tokens)
    -- but it's good enough for a UI indicator.
    return math.ceil(word_count * 1.33)
end

return M
