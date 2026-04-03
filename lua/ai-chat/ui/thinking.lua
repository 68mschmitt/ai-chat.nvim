--- ai-chat.nvim — Thinking block processing
--- Handles detection, styling, folding, and visibility toggling of
--- <thinking>/<think> blocks in streamed AI responses.
---
--- Key design: thinking block lines are NEVER deleted from the buffer.
--- Visibility is controlled via folds — "hide" closes folds, "show" opens
--- them. This allows toggling without re-rendering the conversation.

local M = {}

local config = require("ai-chat.config")
local tokens = require("ai-chat.util.tokens")

--- Thinking tag patterns (both <think> and <thinking> variants).
M.open_pats = { "^<think>%s*$", "^<thinking>%s*$" }
M.close_pats = { "^</think>%s*$", "^</thinking>%s*$" }

--- Stored thinking block ranges per buffer for show/hide toggling.
--- Keyed by bufnr → list of { open, close } (0-indexed line numbers).
---@type table<number, { open: number, close: number }[]>
local block_ranges = {}

--- Check if a line matches a thinking open tag.
---@param line string
---@return boolean
function M.is_open_tag(line)
    for _, pat in ipairs(M.open_pats) do
        if line:match(pat) then
            return true
        end
    end
    return false
end

--- Check if a line matches a thinking close tag.
---@param line string
---@return boolean
function M.is_close_tag(line)
    for _, pat in ipairs(M.close_pats) do
        if line:match(pat) then
            return true
        end
    end
    return false
end

--- Custom foldtext for thinking blocks in the chat buffer.
--- Called by neovim's fold rendering via v:lua.
---@return string
function M.foldtext()
    local line_count = vim.v.foldend - vim.v.foldstart - 1
    return " \u{25b6} Thinking (" .. line_count .. " lines) "
end

--- Find thinking block ranges within a line range.
---@param bufnr number
---@param from_line number  Start line (0-indexed)
---@param to_line number    End line (0-indexed, exclusive)
---@return { open: number, close: number }[]
function M.find_blocks(bufnr, from_line, to_line)
    local lines = vim.api.nvim_buf_get_lines(bufnr, from_line, to_line, false)
    local blocks = {}
    local current_open = nil

    for i, line in ipairs(lines) do
        local abs_line = from_line + i - 1
        if not current_open then
            if M.is_open_tag(line) then
                current_open = abs_line
            end
        else
            if M.is_close_tag(line) then
                table.insert(blocks, { open = current_open, close = abs_line })
                current_open = nil
            end
        end
    end

    return blocks
end

--- Process thinking blocks in a range of lines.
--- Always applies styling and creates folds. If show_thinking is false,
--- the folds are created closed (hiding the content). Lines are never deleted.
---@param bufnr number
---@param ns number          Extmark namespace ID
---@param from_line number   Start line (0-indexed)
---@param to_line number     End line (0-indexed, exclusive)
function M.process(bufnr, ns, from_line, to_line)
    local show_thinking = true
    local cfg = config.get()
    if cfg and cfg.chat then
        show_thinking = cfg.chat.show_thinking ~= false
    end

    local blocks = M.find_blocks(bufnr, from_line, to_line)

    if #blocks == 0 then
        return
    end

    -- Always style blocks (dim, conceal tags, create folds)
    M._style_blocks(bufnr, ns, blocks)

    -- Store ranges for later show/hide toggling
    if not block_ranges[bufnr] then
        block_ranges[bufnr] = {}
    end
    for _, block in ipairs(blocks) do
        table.insert(block_ranges[bufnr], block)
    end

    -- If show_thinking is false, close the folds to hide content
    if not show_thinking then
        M._close_folds(bufnr, blocks)
    end
end

--- Apply visual treatment to thinking blocks (dim, conceal tags, fold).
---@param bufnr number
---@param ns number  Extmark namespace ID
---@param blocks { open: number, close: number }[]
function M._style_blocks(bufnr, ns, blocks)
    for _, block in ipairs(blocks) do
        -- Count tokens in the thinking content (lines between open and close tags)
        local content_lines = vim.api.nvim_buf_get_lines(bufnr, block.open + 1, block.close, false)
        local content_text = table.concat(content_lines, "\n")
        local token_count = tokens.estimate(content_text)

        -- Apply dimmed highlight to all lines in the block (including tags)
        for line_nr = block.open, block.close do
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_nr, 0, {
                line_hl_group = "AiChatThinking",
            })
        end

        -- Conceal the opening tag — replace with a styled header
        local header_text = string.format("\u{25b6} Thinking (%d tokens)", token_count)
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, block.open, 0, {
            virt_text = { { header_text, "AiChatThinkingHeader" } },
            virt_text_pos = "overlay",
        })

        -- Conceal the closing tag
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, block.close, 0, {
            virt_text = { { "", "AiChatThinking" } },
            virt_text_pos = "overlay",
        })

        -- Create a fold over the thinking block content
        -- The fold is created but left OPEN — close_folds() handles hiding
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(win) == bufnr then
                vim.api.nvim_win_call(win, function()
                    vim.wo[win].foldmethod = "manual"
                    vim.wo[win].foldenable = true
                    vim.wo[win].foldminlines = 0
                    vim.wo[win].foldtext = "v:lua.require('ai-chat.ui.thinking').foldtext()"

                    local fold_start = block.open + 1
                    local fold_end = block.close + 1
                    pcall(vim.cmd, fold_start .. "," .. fold_end .. "fold")
                end)
                break
            end
        end
    end
end

--- Close folds for the given thinking blocks (hides them).
---@param bufnr number
---@param blocks { open: number, close: number }[]
function M._close_folds(bufnr, blocks)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            vim.api.nvim_win_call(win, function()
                for _, block in ipairs(blocks) do
                    pcall(vim.cmd, (block.open + 1) .. "foldclose")
                end
            end)
            break
        end
    end
end

--- Open folds for the given thinking blocks (shows them).
---@param bufnr number
---@param blocks { open: number, close: number }[]
function M._open_folds(bufnr, blocks)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            vim.api.nvim_win_call(win, function()
                for _, block in ipairs(blocks) do
                    pcall(vim.cmd, (block.open + 1) .. "foldopen")
                end
            end)
            break
        end
    end
end

--- Toggle thinking block visibility for a buffer.
--- Shows or hides all thinking blocks by opening/closing folds.
---@param bufnr number
---@param visible boolean  true = show thinking blocks, false = hide them
function M.set_visible(bufnr, visible)
    local ranges = block_ranges[bufnr]
    if not ranges or #ranges == 0 then
        return
    end

    if visible then
        M._open_folds(bufnr, ranges)
    else
        M._close_folds(bufnr, ranges)
    end
end

--- Clear stored block ranges for a buffer (called on conversation clear).
---@param bufnr number
function M.clear_ranges(bufnr)
    block_ranges[bufnr] = nil
end

--- Apply real-time dimming to a single line during streaming.
--- Called by the stream renderer as chunks arrive.
---@param bufnr number
---@param ns number       Extmark namespace ID
---@param line_nr number  0-indexed line number
function M.dim_line(bufnr, ns, line_nr)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_nr, 0, {
        line_hl_group = "AiChatThinking",
    })
end

return M
