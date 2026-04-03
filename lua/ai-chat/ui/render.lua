--- ai-chat.nvim — Message rendering
--- Renders conversation messages into the chat buffer.
--- Handles markdown formatting, code block detection, syntax highlighting,
--- and extmark-based metadata display.
---
--- Thinking block processing is delegated to ui/thinking.lua.

local M = {}

local ns = vim.api.nvim_create_namespace("ai-chat-render")
local thinking = require("ai-chat.ui.thinking")
local errors = require("ai-chat.errors")
local code_blocks = require("ai-chat.ui.code_blocks")

--- Execute a function with the buffer set to modifiable.
--- Guarantees modifiable is restored to false even on error.
---@param bufnr number
---@param fn function
local function with_modifiable(bufnr, fn)
    vim.bo[bufnr].modifiable = true
    local ok, err = pcall(fn)
    vim.bo[bufnr].modifiable = false
    if not ok then
        error(err, 2)
    end
end

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
    with_modifiable(bufnr, function()
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
        code_blocks.highlight(bufnr, ns, start_line, start_line + #content_lines)
    end)
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
    with_modifiable(bufnr, function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end)
end

--- Begin a streaming response. Returns an object with append/finish/error methods.
---@param bufnr number
---@return { append: fun(text: string), finish: fun(usage: AiChatUsage, cost_display: string?), error: fun(err: AiChatError) }
function M.begin_response(bufnr)
    -- Capture config once for the lifetime of this streaming response (GAP-23)
    local chat_config = require("ai-chat.config").get().chat

    -- Declare these outside with_modifiable so closures can access them
    local header_line
    local write_line

    with_modifiable(bufnr, function()
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
        write_line = header_line + 1
        vim.api.nvim_buf_set_lines(bufnr, write_line, write_line, false, { "" })
    end)

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

                with_modifiable(bufnr, function()
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
                end)

                -- Auto-scroll only if enabled and user hasn't scrolled up
                if chat_config and chat_config.auto_scroll then
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
        ---@param cost_display string?  Pre-computed cost display string (GAP-08)
        finish = function(usage, cost_display)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    return
                end

                with_modifiable(bufnr, function()
                    -- Flush any remaining content in line_buffer
                    if line_buffer ~= "" then
                        vim.api.nvim_buf_set_lines(bufnr, write_line, write_line + 1, false, { line_buffer })
                        line_buffer = ""
                    end

                    -- Add usage metadata to the header line
                    if usage then
                        local meta = string.format("%d->%d", usage.input_tokens, usage.output_tokens)
                        if cost_display then
                            meta = meta .. " | " .. cost_display
                        end
                        vim.api.nvim_buf_set_extmark(bufnr, ns, header_line, 0, {
                            virt_text = { { " [" .. meta .. "]", "AiChatMeta" } },
                            virt_text_pos = "eol",
                        })
                    end
                end)

                -- Process thinking blocks (fold/collapse) and code blocks (highlight)
                local content_start = header_line + 1
                local content_end = vim.api.nvim_buf_line_count(bufnr)
                thinking.process(bufnr, ns, content_start, content_end)
                code_blocks.highlight(bufnr, ns, content_start, content_end)
            end)
        end,

        --- Display an error in place of the response.
        ---@param err AiChatError
        error = function(err)
            vim.schedule(function()
                if not vim.api.nvim_buf_is_valid(bufnr) then
                    return
                end

                with_modifiable(bufnr, function()
                    local error_lines = {
                        string.rep("-", 50),
                        "  ERROR: " .. (err.message or "Unknown error"),
                    }

                    if errors.is_retryable(err) then
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
                end)
            end)
        end,
    }
end

--- Get the code block at the current cursor position.
--- Delegates to code_blocks module.
M.get_code_block_at_cursor = code_blocks.get_code_block_at_cursor

--- Expose the render namespace ID for other modules.
---@return number
function M.get_namespace()
    return ns
end

--- Keep foldtext available via the old path for backward compatibility.
--- Delegates to the thinking module.
M.foldtext = thinking.foldtext

return M
