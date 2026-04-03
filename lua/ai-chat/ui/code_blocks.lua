--- ai-chat.nvim — Code block detection and markup styling
--- Finds fenced code blocks in chat buffer content, applies syntax
--- highlighting to fences and bold delimiters, and locates the code
--- block under the user's cursor for yank/open operations.

local M = {}

--- Get the code block at the current cursor position.
---@param bufnr number
---@param winid number
---@return { language: string?, content: string, start_line: number, end_line: number }?
function M.get_code_block_at_cursor(bufnr, winid)
    if not vim.api.nvim_win_is_valid(winid) then
        return nil
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    local cursor_line = cursor[1] - 1 -- Convert to 0-indexed
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    -- Scan through all lines to find code blocks
    -- Track opening and closing fences
    local blocks = {}
    local current_block = nil

    for i, line in ipairs(lines) do
        local idx = i - 1 -- 0-indexed
        if not current_block then
            local lang = line:match("^```(%w+)")
            if lang then
                current_block = { start = idx, language = lang }
            end
        else
            if line:match("^```%s*$") then
                current_block.finish = idx
                table.insert(blocks, current_block)
                current_block = nil
            end
        end
    end

    -- Find which block contains the cursor
    for _, block in ipairs(blocks) do
        if cursor_line >= block.start and cursor_line <= block.finish then
            local content_lines = {}
            for j = block.start + 2, block.finish do -- +2: skip fence line (1-indexed)
                table.insert(content_lines, lines[j])
            end
            return {
                language = block.language,
                content = table.concat(content_lines, "\n"),
                start_line = block.start,
                end_line = block.finish,
            }
        end
    end

    return nil
end

--- Apply markup styling to a range of lines.
--- Dims code block fences with AiChatMeta highlight. When treesitter is
--- not active, also conceals **bold** delimiters via extmarks as a fallback.
---@param bufnr number
---@param ns number          Extmark namespace ID
---@param from_line number   Start line (0-indexed)
---@param to_line number     End line (0-indexed, exclusive)
function M.highlight(bufnr, ns, from_line, to_line)
    local lines = vim.api.nvim_buf_get_lines(bufnr, from_line, to_line, false)
    local in_block = false
    -- Only apply extmark-based bold concealment when treesitter is not handling it
    local has_ts = pcall(vim.treesitter.get_parser, bufnr)

    for i, line in ipairs(lines) do
        local abs_line = from_line + i - 1
        if not in_block then
            if line:match("^```") then
                in_block = true
                -- Dim the fence line (complements treesitter, not redundant)
                pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, abs_line, 0, {
                    line_hl_group = "AiChatMeta",
                })
            elseif not has_ts then
                -- Conceal **bold** delimiters when treesitter is unavailable
                M.conceal_bold(bufnr, ns, abs_line, line)
            end
        else
            if line:match("^```%s*$") then
                in_block = false
                pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, abs_line, 0, {
                    line_hl_group = "AiChatMeta",
                })
            end
        end
    end
end

--- Conceal **bold** delimiters on a single line using extmarks.
--- Hides the ** markers and applies bold highlighting to the content between them.
---@param bufnr number
---@param ns number          Extmark namespace ID
---@param line_nr number     0-indexed line number
---@param text string        Line content
function M.conceal_bold(bufnr, ns, line_nr, text)
    local pos = 1
    while pos <= #text do
        local s, e = text:find("%*%*(.-)%*%*", pos)
        if not s then
            break
        end
        -- Only process if there's actual content between the delimiters
        if e - s > 3 then
            -- Conceal opening **
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_nr, s - 1, {
                end_col = s + 1,
                conceal = "",
            })
            -- Apply bold highlight to content
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_nr, s + 1, {
                end_col = e - 2,
                hl_group = "@markup.strong",
            })
            -- Conceal closing **
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line_nr, e - 2, {
                end_col = e,
                conceal = "",
            })
        end
        pos = e + 1
    end
end

return M
