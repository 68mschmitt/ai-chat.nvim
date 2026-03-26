--- ai-chat.nvim — Anthropic provider
--- Direct Anthropic API access. Supports Claude models and extended thinking.
--- Endpoint: https://api.anthropic.com/v1/messages (SSE streaming)

local M = {}

M.name = "anthropic"

---@param config table
---@return boolean ok
---@return string? error_message
function M.validate(config)
    local api_key = (config and config.api_key) or vim.env.ANTHROPIC_API_KEY
    if not api_key or api_key == "" then
        return false, "No Anthropic API key. Set ANTHROPIC_API_KEY env var."
    end
    return true
end

---@param config table
---@param callback fun(models: string[])
function M.list_models(config, callback)
    -- Anthropic doesn't have a models list endpoint; return known models
    callback({
        "claude-sonnet-4-20250514",
        "claude-opus-4-20250514",
        "claude-3-5-haiku-20241022",
    })
end

--- Async preflight check. Verifies the API key is set.
---@param provider_config? table
---@param callback? fun(ok: boolean, err?: string)
function M.preflight(provider_config, callback)
    local api_key = (provider_config or {}).api_key or vim.env.ANTHROPIC_API_KEY
    if not api_key or api_key == "" then
        local msg = "[ai-chat] Anthropic API key not set. Set ANTHROPIC_API_KEY environment variable."
        vim.notify(msg, vim.log.levels.WARN)
        if callback then
            callback(false, msg)
        end
    else
        if callback then
            callback(true)
        end
    end
end

--- Send a chat request with streaming.
---@param messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param callbacks AiChatCallbacks
---@return CancelFn
function M.chat(messages, opts, callbacks)
    local cfg = require("ai-chat.config").get()
    local provider_config = cfg.providers.anthropic or {}
    local api_key = provider_config.api_key or vim.env.ANTHROPIC_API_KEY

    if not api_key or api_key == "" then
        vim.schedule(function()
            callbacks.on_error({
                code = "auth",
                message = "No Anthropic API key. Set ANTHROPIC_API_KEY env var.",
            })
        end)
        return function() end
    end

    -- Separate system prompt from messages (Anthropic API requirement)
    local system_prompt = nil
    local api_messages = {}
    for _, msg in ipairs(messages) do
        if msg.role == "system" then
            system_prompt = msg.content
        else
            table.insert(api_messages, { role = msg.role, content = msg.content })
        end
    end

    -- Build request body
    local body_table = {
        model = opts.model or provider_config.model or "claude-sonnet-4-20250514",
        messages = api_messages,
        max_tokens = opts.max_tokens or provider_config.max_tokens or 8192,
        stream = true,
    }

    if system_prompt then
        body_table.system = system_prompt
    end

    -- Temperature is not allowed when thinking is enabled
    if opts.temperature and not opts.thinking then
        body_table.temperature = opts.temperature
    end

    -- Build curl headers
    local curl_args = {
        "curl",
        "--no-buffer",
        "-s",
        "--connect-timeout",
        "10",
        "-H",
        "Content-Type: application/json",
        "-H",
        "x-api-key: " .. api_key,
        "-H",
        "anthropic-version: 2023-06-01",
    }

    -- Thinking mode
    if opts.thinking then
        local budget = provider_config.thinking_budget or 10000
        body_table.thinking = {
            type = "enabled",
            budget_tokens = budget,
        }
        table.insert(curl_args, "-H")
        table.insert(curl_args, "anthropic-beta: interleaved-thinking-2025-05-14")
    end

    local body = vim.json.encode(body_table)
    local tmpfile = vim.fn.tempname()
    vim.fn.writefile({ body }, tmpfile)

    table.insert(curl_args, "-d")
    table.insert(curl_args, "@" .. tmpfile)
    table.insert(curl_args, "https://api.anthropic.com/v1/messages")

    -- SSE parsing state
    local accumulated_text = ""
    local accumulated_thinking = ""
    local current_block_type = nil
    local usage = { input_tokens = 0, output_tokens = 0, thinking_tokens = 0 }
    local errored = false
    local sse_buffer = ""

    local handle = vim.system(curl_args, {
        stdout = function(err, data)
            if err then
                if not errored then
                    errored = true
                    vim.schedule(function()
                        callbacks.on_error({
                            code = "network",
                            message = "Anthropic connection failed: " .. tostring(err),
                            retryable = true,
                        })
                    end)
                end
                return
            end

            if not data or data == "" then
                return
            end

            sse_buffer = sse_buffer .. data

            -- Process complete SSE events (double newline separated)
            while true do
                local event_end = sse_buffer:find("\n\n")
                if not event_end then
                    break
                end

                local event_block = sse_buffer:sub(1, event_end - 1)
                sse_buffer = sse_buffer:sub(event_end + 2)

                -- Parse event type and data
                local event_type, event_data
                for line in event_block:gmatch("[^\n]+") do
                    local key, val = line:match("^(%w+):%s*(.*)")
                    if key == "event" then
                        event_type = val
                    elseif key == "data" then
                        event_data = val
                    end
                end

                if event_data then
                    local ok, parsed = pcall(vim.json.decode, event_data)
                    if ok and parsed then
                        -- Route by event type
                        if parsed.type == "error" then
                            if not errored then
                                errored = true
                                local err_msg = "Anthropic API error"
                                if parsed.error and parsed.error.message then
                                    err_msg = parsed.error.message
                                end
                                local err_code = "server"
                                if parsed.error and parsed.error.type == "rate_limit_error" then
                                    err_code = "rate_limit"
                                elseif parsed.error and parsed.error.type == "authentication_error" then
                                    err_code = "auth"
                                elseif parsed.error and parsed.error.type == "invalid_request_error" then
                                    err_code = "invalid_request"
                                elseif parsed.error and parsed.error.type == "not_found_error" then
                                    err_code = "model_not_found"
                                end
                                vim.schedule(function()
                                    callbacks.on_error({
                                        code = err_code,
                                        message = err_msg,
                                        retry_after = parsed.error and parsed.error.retry_after,
                                    })
                                end)
                            end
                        elseif parsed.type == "message_start" then
                            -- Extract input token count
                            if parsed.message and parsed.message.usage then
                                usage.input_tokens = parsed.message.usage.input_tokens or 0
                            end
                        elseif parsed.type == "content_block_start" then
                            if parsed.content_block then
                                current_block_type = parsed.content_block.type
                                -- Emit opening tag so the renderer can detect thinking blocks
                                if current_block_type == "thinking" then
                                    vim.schedule(function()
                                        callbacks.on_chunk("<thinking>\n")
                                    end)
                                end
                            end
                        elseif parsed.type == "content_block_delta" then
                            if parsed.delta then
                                if parsed.delta.type == "thinking_delta" and parsed.delta.thinking then
                                    accumulated_thinking = accumulated_thinking .. parsed.delta.thinking
                                    -- Send thinking through on_chunk so the renderer can display it
                                    local text = parsed.delta.thinking
                                    vim.schedule(function()
                                        callbacks.on_chunk(text)
                                    end)
                                elseif parsed.delta.type == "text_delta" and parsed.delta.text then
                                    accumulated_text = accumulated_text .. parsed.delta.text
                                    local text = parsed.delta.text
                                    vim.schedule(function()
                                        callbacks.on_chunk(text)
                                    end)
                                end
                            end
                        elseif parsed.type == "content_block_stop" then
                            -- Emit closing tag when leaving a thinking block
                            if current_block_type == "thinking" then
                                vim.schedule(function()
                                    callbacks.on_chunk("\n</thinking>\n")
                                end)
                            end
                            current_block_type = nil
                        elseif parsed.type == "message_delta" then
                            -- Extract output token count and stop reason
                            if parsed.usage then
                                usage.output_tokens = parsed.usage.output_tokens or 0
                            end
                        elseif parsed.type == "message_stop" then
                            -- Stream complete — handled by on_exit callback
                        end
                    end
                end
            end
        end,
    }, function(result)
        -- Clean up temp file
        pcall(vim.fn.delete, tmpfile)

        if errored then
            return
        end

        vim.schedule(function()
            if result.code ~= 0 then
                -- Check if stdout contains an error response
                if result.stdout and result.stdout ~= "" then
                    local ok, err_data = pcall(vim.json.decode, result.stdout)
                    if ok and err_data and err_data.error then
                        local err_type = err_data.error.type or "unknown"
                        callbacks.on_error({
                            code = err_type == "authentication_error" and "auth"
                                or err_type == "rate_limit_error" and "rate_limit"
                                or err_type == "invalid_request_error" and "invalid_request"
                                or err_type == "not_found_error" and "model_not_found"
                                or "server",
                            message = err_data.error.message or "Anthropic API error",
                        })
                        return
                    end
                end
                callbacks.on_error({
                    code = "network",
                    message = "Anthropic request failed (curl exit " .. result.code .. ")",
                    retryable = true,
                })
            else
                -- Calculate thinking tokens from accumulated content
                if accumulated_thinking ~= "" then
                    usage.thinking_tokens = require("ai-chat.util.tokens").estimate(accumulated_thinking)
                end

                callbacks.on_done({
                    content = accumulated_text,
                    thinking = accumulated_thinking ~= "" and accumulated_thinking or nil,
                    usage = usage,
                    model = opts.model or provider_config.model or "claude-sonnet-4-20250514",
                })
            end
        end)
    end)

    -- Return cancel function
    return function()
        pcall(vim.fn.delete, tmpfile)
        if handle then
            handle:kill("sigterm")
        end
    end
end

return M
