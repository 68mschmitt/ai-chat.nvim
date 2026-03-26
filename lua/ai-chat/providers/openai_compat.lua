--- ai-chat.nvim — OpenAI-compatible provider
--- Covers: OpenAI, Azure OpenAI, Groq, Together, LM Studio, etc.
--- Endpoint: configurable (default: https://api.openai.com/v1/chat/completions)
--- Streaming: SSE with data: {"choices":[{"delta":{"content":"..."}}]}

local M = {}

M.name = "openai_compat"

---@param config table
---@return boolean ok
---@return string? error_message
function M.validate(config)
    local api_key = (config and config.api_key) or vim.env.OPENAI_API_KEY
    if not api_key or api_key == "" then
        return false, "No OpenAI API key. Set OPENAI_API_KEY env var."
    end
    if not config.endpoint then
        return false, "No endpoint configured for OpenAI-compatible provider."
    end
    return true
end

---@param config table
---@param callback fun(models: string[])
function M.list_models(config, callback)
    local api_key = (config and config.api_key) or vim.env.OPENAI_API_KEY
    local endpoint = config.endpoint or "https://api.openai.com/v1"

    -- Try to fetch models from the API
    local models_url = endpoint:gsub("/chat/completions$", "") .. "/models"

    vim.system(
        { "curl", "-s", "--connect-timeout", "3", "-H", "Authorization: Bearer " .. (api_key or ""), models_url },
        {},
        function(result)
            vim.schedule(function()
                if result.code ~= 0 then
                    -- Fallback to known models
                    callback({ "gpt-4o", "gpt-4o-mini", "gpt-4-turbo" })
                    return
                end
                local ok, data = pcall(vim.json.decode, result.stdout)
                if not ok or not data or not data.data then
                    callback({ "gpt-4o", "gpt-4o-mini", "gpt-4-turbo" })
                    return
                end
                local models = {}
                for _, model in ipairs(data.data) do
                    if model.id then
                        table.insert(models, model.id)
                    end
                end
                table.sort(models)
                if #models == 0 then
                    callback({ "gpt-4o", "gpt-4o-mini", "gpt-4-turbo" })
                else
                    callback(models)
                end
            end)
        end
    )
end

--- Async preflight check. Verifies the API key is set.
---@param provider_config? table
---@param callback? fun(ok: boolean, err?: string)
function M.preflight(provider_config, callback)
    local api_key = (provider_config or {}).api_key or vim.env.OPENAI_API_KEY
    if not api_key or api_key == "" then
        local msg = "[ai-chat] OpenAI API key not set. Set OPENAI_API_KEY environment variable."
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
    local provider_config = cfg.providers.openai_compat or {}
    local api_key = provider_config.api_key or vim.env.OPENAI_API_KEY
    local endpoint = provider_config.endpoint or "https://api.openai.com/v1/chat/completions"

    if not api_key or api_key == "" then
        vim.schedule(function()
            callbacks.on_error({
                code = "auth",
                message = "No OpenAI API key. Set OPENAI_API_KEY env var.",
            })
        end)
        return function() end
    end

    -- Build request body
    local body_table = {
        model = opts.model or provider_config.model or "gpt-4o",
        messages = messages,
        temperature = opts.temperature or 0.7,
        max_tokens = opts.max_tokens or 4096,
        stream = true,
        -- Request usage in stream (OpenAI extension)
        stream_options = { include_usage = true },
    }

    local body = vim.json.encode(body_table)
    local tmpfile = vim.fn.tempname()
    vim.fn.writefile({ body }, tmpfile)

    -- SSE parsing state
    local accumulated = ""
    local usage = { input_tokens = 0, output_tokens = 0 }
    local errored = false
    local sse_buffer = ""

    local handle = vim.system({
        "curl",
        "--no-buffer",
        "-s",
        "--connect-timeout",
        "10",
        "-H",
        "Content-Type: application/json",
        "-H",
        "Authorization: Bearer " .. api_key,
        "-d",
        "@" .. tmpfile,
        endpoint,
    }, {
        stdout = function(err, data)
            if err then
                if not errored then
                    errored = true
                    vim.schedule(function()
                        callbacks.on_error({
                            code = "network",
                            message = "OpenAI connection failed: " .. tostring(err),
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

            -- Process SSE lines
            while true do
                local line_end = sse_buffer:find("\n")
                if not line_end then
                    break
                end

                local line = sse_buffer:sub(1, line_end - 1)
                sse_buffer = sse_buffer:sub(line_end + 1)

                -- Skip empty lines (SSE event separators) and non-data lines
                if line ~= "" and line ~= "\r" then
                    -- Strip carriage return
                    line = line:gsub("\r$", "")

                    -- Parse "data: ..." lines
                    local payload = line:match("^data:%s*(.*)")

                    -- Process payload if it's a valid data line and not the [DONE] sentinel
                    if payload and payload ~= "[DONE]" then
                        local ok, chunk = pcall(vim.json.decode, payload)
                        if ok and chunk then
                            -- Check for API error in response
                            if chunk.error then
                                if not errored then
                                    errored = true
                                    local err_code = "server"
                                    local err_msg = chunk.error.message or "OpenAI API error"
                                    if err_msg:match("rate limit") or chunk.error.type == "rate_limit" then
                                        err_code = "rate_limit"
                                    elseif
                                        chunk.error.type == "invalid_api_key"
                                        or chunk.error.code == "invalid_api_key"
                                    then
                                        err_code = "auth"
                                    elseif chunk.error.code == "model_not_found" then
                                        err_code = "model_not_found"
                                    elseif chunk.error.type == "invalid_request_error" then
                                        err_code = "invalid_request"
                                    end
                                    vim.schedule(function()
                                        callbacks.on_error({
                                            code = err_code,
                                            message = err_msg,
                                        })
                                    end)
                                end
                            else
                                -- Extract content delta
                                if chunk.choices and chunk.choices[1] then
                                    local delta = chunk.choices[1].delta
                                    if delta and delta.content then
                                        accumulated = accumulated .. delta.content
                                        local text = delta.content
                                        vim.schedule(function()
                                            callbacks.on_chunk(text)
                                        end)
                                    end
                                end

                                -- Extract usage (sent in final chunk with stream_options)
                                if chunk.usage then
                                    usage.input_tokens = chunk.usage.prompt_tokens or 0
                                    usage.output_tokens = chunk.usage.completion_tokens or 0
                                end
                            end
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
                            code = err_type == "invalid_api_key" and "auth"
                                or err_type:match("rate") and "rate_limit"
                                or err_type == "invalid_request_error" and "invalid_request"
                                or "server",
                            message = err_data.error.message or "OpenAI API error",
                        })
                        return
                    end
                end
                callbacks.on_error({
                    code = "network",
                    message = "OpenAI request failed (curl exit " .. result.code .. ")",
                    retryable = true,
                })
            else
                callbacks.on_done({
                    content = accumulated,
                    usage = usage,
                    model = opts.model or provider_config.model or "gpt-4o",
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
