--- ai-chat.nvim — Ollama provider
--- Local inference via Ollama. No API key, no cost, full privacy.
--- Endpoint: http://localhost:11434/api/chat (NDJSON streaming)

local M = {}

M.name = "ollama"

---@param provider_config table  Provider config from setup()
---@return boolean ok
---@return string? error_message
function M.validate(provider_config)
    if not provider_config.host then
        return false, "Ollama host not configured"
    end
    return true
end

--- List available models from the Ollama instance.
---@param provider_config table
---@param callback fun(models: string[])
function M.list_models(provider_config, callback)
    local url = (provider_config.host or "http://localhost:11434") .. "/api/tags"

    vim.system({ "curl", "-s", "--connect-timeout", "3", url }, {}, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback({})
                return
            end
            local ok, data = pcall(vim.json.decode, result.stdout)
            if not ok or not data or not data.models then
                callback({})
                return
            end
            local models = {}
            for _, model in ipairs(data.models) do
                table.insert(models, model.name)
            end
            callback(models)
        end)
    end)
end

--- Send a chat request with streaming.
---@param messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param callbacks AiChatCallbacks
---@return CancelFn
function M.chat(messages, opts, callbacks)
    local cfg = require("ai-chat.config").get()
    local provider_config = cfg.providers.ollama or {}
    local host = provider_config.host or "http://localhost:11434"
    local url = host .. "/api/chat"

    local body = vim.json.encode({
        model = opts.model,
        messages = messages,
        stream = true,
        options = {
            temperature = opts.temperature or 0.7,
            num_predict = opts.max_tokens or 4096,
        },
    })

    local accumulated = ""
    local usage = { input_tokens = 0, output_tokens = 0 }
    local errored = false

    -- Write body to a temp file to avoid shell escaping issues with large payloads
    local tmpfile = vim.fn.tempname()
    vim.fn.writefile({ body }, tmpfile)

    local handle = vim.system({
        "curl",
        "--no-buffer",
        "-s",
        "--connect-timeout",
        "5",
        "-H",
        "Content-Type: application/json",
        "-d",
        "@" .. tmpfile,
        url,
    }, {
        stdout = function(err, data)
            if err then
                if not errored then
                    errored = true
                    vim.schedule(function()
                        callbacks.on_error({
                            code = "network",
                            message = "Ollama connection failed: " .. tostring(err),
                            retryable = true,
                        })
                    end)
                end
                return
            end

            if not data or data == "" then
                return
            end

            -- Ollama streams NDJSON: one JSON object per line
            for line in data:gmatch("[^\n]+") do
                local ok, chunk = pcall(vim.json.decode, line)
                if ok and chunk then
                    if chunk.error then
                        -- Ollama returned an error (e.g., model not found)
                        if not errored then
                            errored = true
                            local err_msg = chunk.error
                            local err_code = "server"
                            -- Classify: model not found is fatal, not retryable
                            if err_msg:match("model") and err_msg:match("not found") then
                                err_code = "model_not_found"
                            end
                            vim.schedule(function()
                                callbacks.on_error({
                                    code = err_code,
                                    message = "Ollama error: " .. err_msg,
                                })
                            end)
                        end
                        return
                    end

                    if chunk.message and chunk.message.content then
                        local text = chunk.message.content
                        accumulated = accumulated .. text
                        vim.schedule(function()
                            callbacks.on_chunk(text)
                        end)
                    end

                    -- Final chunk contains usage stats
                    if chunk.done then
                        usage.input_tokens = chunk.prompt_eval_count or 0
                        usage.output_tokens = chunk.eval_count or 0
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
                callbacks.on_error({
                    code = "network",
                    message = "Ollama request failed. Is Ollama running at "
                        .. host
                        .. "? Start it with `ollama serve`.",
                    retryable = true,
                })
            else
                callbacks.on_done({
                    content = accumulated,
                    usage = usage,
                    model = opts.model,
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

--- Async preflight check. Called once per session before first send.
--- Verifies the Ollama server is reachable and notifies the user if not.
---@param provider_config? table  Provider config (uses defaults if nil)
---@param callback? fun(ok: boolean, err?: string)
function M.preflight(provider_config, callback)
    local host = (provider_config or {}).host or "http://localhost:11434"
    vim.system({ "curl", "-s", "--connect-timeout", "2", host .. "/api/tags" }, {}, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                local msg = "[ai-chat] Ollama not detected at "
                    .. host
                    .. ". Start it with `ollama serve` or switch provider with /provider."
                vim.notify(msg, vim.log.levels.WARN)
                if callback then
                    callback(false, msg)
                end
            else
                if callback then
                    callback(true)
                end
            end
        end)
    end)
end

--- Async check if Ollama is running. Called once per session on first send.
--- Notifies the user if Ollama is unreachable so they can start it or switch provider.
--- @deprecated Use preflight() instead
---@param provider_config? table  Provider config (uses defaults if nil)
function M.check_reachable(provider_config)
    M.preflight(provider_config)
end

return M
