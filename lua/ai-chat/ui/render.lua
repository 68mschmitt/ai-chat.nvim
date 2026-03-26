--- ai-chat.nvim — Message rendering
--- Renders conversation messages into the chat buffer.
--- Handles markdown formatting, code block detection, syntax highlighting,
--- and extmark-based metadata display.

local M = {}

local ns = vim.api.nvim_create_namespace("ai-chat-render")

--- Render a single message into the chat buffer.
---@param bufnr number  Chat buffer
---@param message table  { role, content, context?, usage?, model? }
function M.render_message(bufnr, message)
    vim.bo[bufnr].modifiable = true

    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local start_line = line_count

    -- Add separator if not first message
    if start_line > 1 then
        vim.api.nvim_buf_set_lines(bufnr, start_line, start_line, false, { "" })
        start_line = start_line + 1
    end

    -- Message header
    local header = message.role == "user" and "## You" or "## Assistant"
    vim.api.nvim_buf_set_lines(bufnr, start_line, start_line, false, { header })

    -- Add metadata as virtual text on the header line
    local meta_parts = {}
    if message.context and #message.context > 0 then
        for _, ctx in ipairs(message.context) do
            table.insert(meta_parts, "@" .. ctx.type .. ": " .. ctx.source)
        end
    end
    if message.usage then
        table.insert(meta_parts, string.format(
            "%d→%d",
            message.usage.input_tokens or 0,
            message.usage.output_tokens or 0
        ))
    end
    if #meta_parts > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, ns, start_line, 0, {
            virt_text = { { " [" .. table.concat(meta_parts, " · ") .. "]", "AiChatMeta" } },
            virt_text_pos = "eol",
        })
    end

    -- Apply header highlighting
    local hl_group = message.role == "user" and "AiChatUser" or "AiChatAssistant"
    vim.api.nvim_buf_set_extmark(bufnr, ns, start_line, 0, {
        end_col = #header,
        hl_group = hl_group,
    })

    start_line = start_line + 1

    -- Message content
    local content_lines = vim.split(message.content, "\n")
    vim.api.nvim_buf_set_lines(bufnr, start_line, start_line, false, content_lines)

    -- Apply syntax highlighting to code blocks
    M._highlight_code_blocks(bufnr, start_line, start_line + #content_lines)

    vim.bo[bufnr].modifiable = false
end

--- Render an entire conversation into a fresh chat buffer.
---@param bufnr number
---@param conversation AiChatConversation
function M.render_conversation(bufnr, conversation)
    M.clear(bufnr)
    for _, message in ipairs(conversation.messages) do
        M.render_message(bufnr, message)
    end
end

--- Clear the chat buffer.
---@param bufnr number
function M.clear(bufnr)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    vim.bo[bufnr].modifiable = false
end

--- Begin a streaming response. Returns an object with append/finish/error methods.
---@param bufnr number
---@return { append: fun(text: string), finish: fun(usage: AiChatUsage), error: fun(err: AiChatError) }
function M.begin_response(bufnr)
    -- Add assistant header
    vim.bo[bufnr].modifiable = true
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local header_line = line_count

    -- Separator
    if header_line > 1 then
        vim.api.nvim_buf_set_lines(bufnr, header_line, header_line, false, { "" })
        header_line = header_line + 1
    end

    -- Header
    vim.api.nvim_buf_set_lines(bufnr, header_line, header_line, false, { "## Assistant" })
    vim.api.nvim_buf_set_extmark(bufnr, ns, header_line, 0, {
        end_col = #"## Assistant",
        hl_group = "AiChatAssistant",
    })

    local write_line = header_line + 1
    vim.api.nvim_buf_set_lines(bufnr, write_line, write_line, false, { "" })
    vim.bo[bufnr].modifiable = false

    -- Line buffer for accumulating partial lines
    local line_buffer = ""
    local chat_winid = nil -- Will find from state

    return {
        --- Append a streamed chunk of text.
        ---@param text string
        append = function(text)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then return end

                vim.bo[bufnr].modifiable = true

                line_buffer = line_buffer .. text
                local lines = vim.split(line_buffer, "\n", { plain = true })

                -- Write complete lines
                for i = 1, #lines - 1 do
                    vim.api.nvim_buf_set_lines(bufnr, write_line, write_line + 1, false, { lines[i] })
                    write_line = write_line + 1
                    -- Add empty line for next content
                    vim.api.nvim_buf_set_lines(bufnr, write_line, write_line, false, { "" })
                end

                -- Update incomplete line
                line_buffer = lines[#lines]
                if line_buffer ~= "" then
                    vim.api.nvim_buf_set_lines(bufnr, write_line, write_line + 1, false, { line_buffer })
                end

                vim.bo[bufnr].modifiable = false

                -- Auto-scroll (find chat window)
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    if vim.api.nvim_win_get_buf(win) == bufnr then
                        local last_line = vim.api.nvim_buf_line_count(bufnr)
                        pcall(vim.api.nvim_win_set_cursor, win, { last_line, 0 })
                        break
                    end
                end
            end)
        end,

        --- Finalize the response with usage metadata.
        ---@param usage AiChatUsage
        finish = function(usage)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then return end

                -- Flush remaining line buffer
                if line_buffer ~= "" then
                    vim.bo[bufnr].modifiable = true
                    vim.api.nvim_buf_set_lines(bufnr, write_line, write_line + 1, false, { line_buffer })
                    line_buffer = ""
                    vim.bo[bufnr].modifiable = false
                end

                -- Add usage metadata to the header
                if usage then
                    local cost = require("ai-chat.util.costs").estimate(
                        require("ai-chat").get_config().default_provider,
                        require("ai-chat").get_config().default_model,
                        usage
                    )
                    local meta = string.format("%d→%d", usage.input_tokens, usage.output_tokens)
                    if cost > 0 then
                        meta = meta .. string.format(" · $%.4f", cost)
                    end
                    vim.api.nvim_buf_set_extmark(bufnr, ns, header_line, 0, {
                        virt_text = { { " [" .. meta .. "]", "AiChatMeta" } },
                        virt_text_pos = "eol",
                    })
                end

                -- Apply syntax highlighting to code blocks in the response
                M._highlight_code_blocks(bufnr, header_line + 1, vim.api.nvim_buf_line_count(bufnr))
            end)
        end,

        --- Display an error in place of the response.
        ---@param err AiChatError
        error = function(err)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then return end

                vim.bo[bufnr].modifiable = true

                local error_lines = {
                    "--- Error " .. string.rep("-", 50),
                    "  " .. (err.message or "Unknown error"),
                }

                if err.retryable then
                    table.insert(error_lines, "  Press <CR> to retry, <C-c> to cancel.")
                end

                table.insert(error_lines, string.rep("-", 60))

                vim.api.nvim_buf_set_lines(bufnr, write_line, write_line, false, error_lines)

                -- Highlight error lines
                for i = 0, #error_lines - 1 do
                    vim.api.nvim_buf_set_extmark(bufnr, ns, write_line + i, 0, {
                        line_hl_group = "AiChatError",
                    })
                end

                vim.bo[bufnr].modifiable = false
            end)
        end,
    }
end

--- Get the code block at the current cursor position.
---@param bufnr number
---@param winid number
---@return { language: string?, content: string, start_line: number, end_line: number }?
function M.get_code_block_at_cursor(bufnr, winid)
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local cursor_line = cursor[1] - 1 -- 0-indexed
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    -- Find code block boundaries
    local block_start = nil
    local block_end = nil
    local language = nil

    for i, line in ipairs(lines) do
        local idx = i - 1 -- 0-indexed
        local lang = line:match("^```(%w+)")
        if lang then
            if idx <= cursor_line then
                block_start = idx
                language = lang
                block_end = nil -- Reset, looking for closing fence
            end
        elseif line:match("^```%s*$") then
            if block_start and not block_end then
                block_end = idx
                if cursor_line >= block_start and cursor_line <= block_end then
                    -- Found the block containing cursor
                    local content_lines = {}
                    for j = block_start + 2, block_end do -- +2 to skip fence line (1-indexed)
                        table.insert(content_lines, lines[j])
                    end
                    return {
                        language = language,
                        content = table.concat(content_lines, "\n"),
                        start_line = block_start,
                        end_line = block_end,
                    }
                end
            end
        end
    end

    return nil
end

--- Apply syntax highlighting to code blocks in a range of lines.
---@param bufnr number
---@param from_line number  Start line (0-indexed)
---@param to_line number    End line (0-indexed, exclusive)
function M._highlight_code_blocks(bufnr, from_line, to_line)
    local lines = vim.api.nvim_buf_get_lines(bufnr, from_line, to_line, false)
    local in_block = false
    local block_lang = nil

    for i, line in ipairs(lines) do
        local lang = line:match("^```(%w+)")
        if lang then
            in_block = true
            block_lang = lang
        elseif line:match("^```%s*$") and in_block then
            in_block = false
            block_lang = nil
        end
    end

    -- Treesitter injection will handle actual syntax highlighting
    -- if the treesitter integration is available. The filetype "aichat"
    -- can have injection queries that detect ```lang blocks.
    -- Fallback: no highlighting (still readable).
end

return M
