--- ai-chat.nvim — Message rendering
--- Renders conversation messages into the chat buffer.
--- Handles markdown formatting, code block detection, syntax highlighting,
--- and extmark-based metadata display.
---
--- Thinking block processing is delegated to ui/thinking.lua.

local M = {}

local ns = vim.api.nvim_create_namespace("ai-chat-render")
local thinking = require("ai-chat.ui.thinking")

--- Check if the buffer is "empty" (single empty line from initialization).
---@param bufnr number
---@return boolean
local function buf_is_empty(bufnr)
    local lc = vim.api.nvim_buf_line_count(bufnr)
    if lc ~= 1 then
        return false
    end
    local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)
    return first[1] == ""
end

--- Render a single message into the chat buffer.
---@param bufnr number  Chat buffer
---@param message table  { role, content, context?, usage?, model? }
function M.render_message(bufnr, message)
    vim.bo[bufnr].modifiable = true

    local start_line

    if buf_is_empty(bufnr) then
        -- Replace the initial empty line
        start_line = 0
    else
        -- Append after existing content with a blank separator
        local lc = vim.api.nvim_buf_line_count(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, lc, lc, false, { "" })
        start_line = lc + 1
    end

    -- Message header
    local header = message.role == "user" and "## You" or "## Assistant"
    vim.api.nvim_buf_set_lines(bufnr, start_line, start_line, false, { header })

    -- Add metadata as virtual text on the header line
    local meta_parts = {}
    if message.usage then
        table.insert(
            meta_parts,
            string.format("%d->%d", message.usage.input_tokens or 0, message.usage.output_tokens or 0)
        )
    end
    if #meta_parts > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, ns, start_line, 0, {
            virt_text = { { " [" .. table.concat(meta_parts, " | ") .. "]", "AiChatMeta" } },
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

    -- Apply syntax highlighting to code blocks and thinking blocks
    thinking.process(bufnr, ns, start_line, start_line + #content_lines)
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
    vim.bo[bufnr].modifiable = true

    local header_line

    if buf_is_empty(bufnr) then
        header_line = 0
    else
        local lc = vim.api.nvim_buf_line_count(bufnr)
        -- Add blank separator
        vim.api.nvim_buf_set_lines(bufnr, lc, lc, false, { "" })
        header_line = lc + 1
    end

    -- Header
    vim.api.nvim_buf_set_lines(bufnr, header_line, header_line, false, { "## Assistant" })
    vim.api.nvim_buf_set_extmark(bufnr, ns, header_line, 0, {
        end_col = #"## Assistant",
        hl_group = "AiChatAssistant",
    })

    -- Initialize the first content line
    local write_line = header_line + 1
    vim.api.nvim_buf_set_lines(bufnr, write_line, write_line, false, { "" })
    vim.bo[bufnr].modifiable = false

    -- Line buffer for accumulating partial lines during streaming
    local line_buffer = ""

    -- Thinking block state for real-time dimming during streaming
    local in_thinking = false

    return {
        --- Append a streamed chunk of text.
        ---@param text string
        append = function(text)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    return
                end

                vim.bo[bufnr].modifiable = true

                line_buffer = line_buffer .. text
                local lines = vim.split(line_buffer, "\n", { plain = true })

                -- Process all complete lines (all except the last fragment)
                for i = 1, #lines - 1 do
                    local line_text = lines[i]
                    -- Replace the current write_line with the complete line
                    vim.api.nvim_buf_set_lines(bufnr, write_line, write_line + 1, false, { line_text })

                    -- Track thinking state and apply real-time dimming
                    if thinking.is_open_tag(line_text) then
                        in_thinking = true
                    end

                    if in_thinking then
                        thinking.dim_line(bufnr, ns, write_line)
                    end

                    if thinking.is_close_tag(line_text) then
                        in_thinking = false
                    end

                    write_line = write_line + 1
                    -- Insert a fresh empty line for the next content
                    vim.api.nvim_buf_set_lines(bufnr, write_line, write_line, false, { "" })
                end

                -- The last element is the incomplete trailing fragment
                line_buffer = lines[#lines]
                -- Update the current line with the fragment (overwrite in place)
                vim.api.nvim_buf_set_lines(bufnr, write_line, write_line + 1, false, { line_buffer })

                vim.bo[bufnr].modifiable = false

                -- Auto-scroll only if enabled and user hasn't scrolled up
                local ok_cfg, chat_config = pcall(function()
                    return require("ai-chat.config").get().chat
                end)
                if ok_cfg and chat_config and chat_config.auto_scroll then
                    for _, win in ipairs(vim.api.nvim_list_wins()) do
                        if vim.api.nvim_win_get_buf(win) == bufnr then
                            local last = vim.api.nvim_buf_line_count(bufnr)
                            local win_height = vim.api.nvim_win_get_height(win)
                            local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
                            -- Only scroll if user is near the bottom
                            if cursor_line >= last - win_height - 5 then
                                pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
                            end
                            break
                        end
                    end
                end
            end)
        end,

        --- Finalize the response with usage metadata.
        ---@param usage AiChatUsage
        ---@param opts? { provider?: string, model?: string }
        finish = function(usage, opts)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    return
                end
                opts = opts or {}

                -- Flush any remaining content in line_buffer
                if line_buffer ~= "" then
                    vim.bo[bufnr].modifiable = true
                    vim.api.nvim_buf_set_lines(bufnr, write_line, write_line + 1, false, { line_buffer })
                    line_buffer = ""
                    vim.bo[bufnr].modifiable = false
                end

                -- Add usage metadata to the header line
                if usage then
                    local meta = string.format("%d->%d", usage.input_tokens, usage.output_tokens)
                    local provider = opts.provider or require("ai-chat.config").get().default_provider
                    local model = opts.model or require("ai-chat.config").get().default_model
                    local registry = require("ai-chat.models")
                    local reg_pricing = registry.get_pricing(provider, model)
                    local cost = require("ai-chat.util.costs").estimate(provider, model, usage, reg_pricing)
                    if cost > 0 then
                        meta = meta .. string.format(" | $%.4f", cost)
                    end
                    vim.api.nvim_buf_set_extmark(bufnr, ns, header_line, 0, {
                        virt_text = { { " [" .. meta .. "]", "AiChatMeta" } },
                        virt_text_pos = "eol",
                    })
                end

                -- Process thinking blocks (fold/collapse) and code blocks (highlight)
                local content_start = header_line + 1
                local content_end = vim.api.nvim_buf_line_count(bufnr)
                thinking.process(bufnr, ns, content_start, content_end)
                M._highlight_code_blocks(bufnr, content_start, content_end)
            end)
        end,

        --- Display an error in place of the response.
        ---@param err AiChatError
        error = function(err)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    return
                end

                vim.bo[bufnr].modifiable = true

                local error_lines = {
                    string.rep("-", 50),
                    "  ERROR: " .. (err.message or "Unknown error"),
                }

                if require("ai-chat.errors").is_retryable(err) then
                    table.insert(error_lines, "  (retryable)")
                end

                table.insert(error_lines, string.rep("-", 50))

                vim.api.nvim_buf_set_lines(bufnr, write_line, write_line + 1, false, error_lines)

                -- Highlight error lines
                for i = 0, #error_lines - 1 do
                    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, write_line + i, 0, {
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
--- Dims code block fences with AiChatMeta. When treesitter is not active,
--- also conceals **bold** delimiters via extmarks as a fallback (treesitter's
--- markdown_inline parser handles concealment when available).
---@param bufnr number
---@param from_line number  Start line (0-indexed)
---@param to_line number    End line (0-indexed, exclusive)
function M._highlight_code_blocks(bufnr, from_line, to_line)
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
                M._conceal_bold(bufnr, abs_line, line)
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
---@param line_nr number  0-indexed line number
---@param text string     Line content
function M._conceal_bold(bufnr, line_nr, text)
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

--- Expose the render namespace ID for other modules.
---@return number
function M.get_namespace()
    return ns
end

--- Keep foldtext available via the old path for backward compatibility.
--- Delegates to the thinking module.
M.foldtext = thinking.foldtext

return M
