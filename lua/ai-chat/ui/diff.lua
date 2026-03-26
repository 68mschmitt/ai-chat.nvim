--- ai-chat.nvim — Diff-based code application
--- Opens a diff split to review and apply AI-suggested code changes.

local M = {}

--- Apply a code block by opening a diff split.
---@param block { language: string?, content: string, start_line: number, end_line: number }
function M.apply(block)
    -- Determine the target file
    -- Strategy:
    -- 1. If the user had @buffer context, use that file
    -- 2. If the code block has a file path hint, use that
    -- 3. Use the alternate buffer (#)
    -- 4. Prompt the user

    local target_bufnr = M._find_target_buffer(block)

    if not target_bufnr then
        vim.notify("[ai-chat] Could not determine target file for code application", vim.log.levels.WARN)
        return
    end

    -- Get the target file info
    local target_file = vim.api.nvim_buf_get_name(target_bufnr)
    if target_file == "" then
        vim.notify("[ai-chat] Target buffer has no file name", vim.log.levels.WARN)
        return
    end

    -- Focus the code area (left of chat split)
    vim.cmd("wincmd p")

    -- Ensure the target buffer is visible
    if vim.api.nvim_get_current_buf() ~= target_bufnr then
        vim.api.nvim_set_current_buf(target_bufnr)
    end

    -- Enable diff mode on the original
    vim.cmd("diffthis")

    -- Create a vertical split with the suggested content
    vim.cmd("vnew")
    local suggested_bufnr = vim.api.nvim_get_current_buf()

    -- Set up the suggested buffer
    local lines = vim.split(block.content, "\n")
    vim.api.nvim_buf_set_lines(suggested_bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_name(suggested_bufnr, "ai-chat://suggested")

    -- Match filetype for syntax highlighting
    if block.language then
        vim.bo[suggested_bufnr].filetype = block.language
    else
        vim.bo[suggested_bufnr].filetype = vim.bo[target_bufnr].filetype
    end

    vim.bo[suggested_bufnr].buftype = "nofile"
    vim.bo[suggested_bufnr].bufhidden = "wipe"
    vim.bo[suggested_bufnr].swapfile = false

    -- Enable diff mode on the suggestion
    vim.cmd("diffthis")

    -- Helpful message
    vim.notify(
        "[ai-chat] Diff view: use ]c/[c to navigate, do/dp to apply, :diffoff|only to finish",
        vim.log.levels.INFO
    )

    -- Set up autocommand to clean up diff mode when the suggested buffer is closed
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = suggested_bufnr,
        once = true,
        callback = function()
            -- Turn off diff in the original buffer
            if vim.api.nvim_buf_is_valid(target_bufnr) then
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if vim.api.nvim_win_get_buf(win) == target_bufnr then
                        vim.api.nvim_win_call(win, function()
                            vim.cmd("diffoff")
                        end)
                    end
                end
            end
        end,
    })
end

--- Find the most likely target buffer for applying code.
---@param block table
---@return number?  Buffer number, or nil if not found
function M._find_target_buffer(block)
    -- Try the alternate buffer first (the buffer the user was editing)
    local alt = vim.fn.bufnr("#")
    if alt > 0 and vim.api.nvim_buf_is_valid(alt) and vim.bo[alt].buftype == "" then
        return alt
    end

    -- Try the most recently used non-special buffer
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) ~= "" then
            return buf
        end
    end

    return nil
end

return M
