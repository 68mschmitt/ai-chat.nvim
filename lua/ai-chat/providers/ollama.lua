--- ai-chat.nvim — Ollama provider
--- Local inference via Ollama. No API key, no cost, full privacy.
--- Endpoint: http://localhost:11434/api/chat (NDJSON streaming)

local M = {}

M.name = "ollama"

---@param config table  Provider config from setup()
---@return boolean ok
---@return string? error_message
function M.validate(config)
    if not config.host then
        return false, "Ollama host not configured"
    end
    return true
end

--- List available models from the Ollama instance.
---@param config table
---@param callback fun(models: string[])
function M.list_models(config, callback)
    local url = (config.host or "http://localhost:11434") .. "/api/tags"

    vim.system(
        { "curl", "-s", url },
        {},
        function(result)
            vim.schedule(function()
                if result.code ~= 0 then
                    callback({})
                    return
                end
                local ok, data = pcall(vim.fn.json_decode, result.stdout)
                if not ok or not data.models then
                    callback({})
                    return
                end
                local models = {}
                for _, model in ipairs(data.models) do
                    table.insert(models, model.name)
                end
                callback(models)
            end)
        end
    )
end

--- Send a chat request with streaming.
---@param messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param callbacks AiChatCallbacks
---@return CancelFn
function M.chat(messages, opts, callbacks)
    local config = require("ai-chat.config").resolve({}).providers.ollama
    local url = (config.host or "http://localhost:11434") .. "/api/chat"

    local body = vim.fn.json_encode({
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

    local handle = vim.system(
        { "curl", "--no-buffer", "-s",
          "-H", "Content-Type: application/json",
          "-d", body,
          url },
        {
            stdout = function(err, data)
                if err then
                    vim.schedule(function()
                        callbacks.on_error({
                            code = "network",
                            message = "Ollama connection failed: " .. err,
                            retryable = true,
                        })
                    end)
                    return
                end

                if not data or data == "" then return end

                -- Ollama streams NDJSON: one JSON object per line
                for line in data:gmatch("[^\n]+") do
                    local ok, chunk = pcall(vim.fn.json_decode, line)
                    if ok and chunk then
                        if chunk.message and chunk.message.content then
                            local text = chunk.message.content
                            accumulated = accumulated .. text
                            callbacks.on_chunk(text)
                        end

                        -- Final chunk contains usage stats
                        if chunk.done then
                            usage.input_tokens = chunk.prompt_eval_count or 0
                            usage.output_tokens = chunk.eval_count or 0
                        end
                    end
                end
            end,
        },
        function(result)
            vim.schedule(function()
                if result.code ~= 0 then
                    callbacks.on_error({
                        code = "network",
                        message = "Ollama request failed (exit code " .. result.code .. ")",
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
        end
    )

    -- Return cancel function
    return function()
        handle:kill("sigterm")
    end
end

return M
