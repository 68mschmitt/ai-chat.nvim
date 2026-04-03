--- ai-chat.nvim — Amazon Bedrock provider
--- Enterprise Claude access via AWS Bedrock InvokeModelWithResponseStream API.
--- Auth: Bearer token via AWS_BEARER_TOKEN_BEDROCK env variable.
---
--- Uses the InvokeModelWithResponseStream endpoint with the native Anthropic
--- Messages API format (anthropic_version = "bedrock-2023-05-31").
--- Response stream contains event{...} frames with Base64-encoded Anthropic
--- JSON payloads — same format as direct Anthropic API after decoding.
---
--- Reference: https://github.com/yetone/avante.nvim/blob/main/lua/avante/providers/bedrock.lua

local codec = require("ai-chat.providers.bedrock_codec")

local M = {}

M.name = "Amazon Bedrock"

---@param config table
---@return boolean ok
---@return string? error_message
function M.validate(config)
    if not config.region then
        return false, "Bedrock region not configured."
    end
    local token = (config and config.bearer_token) or vim.env.AWS_BEARER_TOKEN_BEDROCK
    if not token or token == "" then
        return false, "No Bedrock bearer token. Set AWS_BEARER_TOKEN_BEDROCK env var."
    end
    return true
end

---@param config table
---@param callback fun(models: string[])
function M.list_models(config, callback)
    callback({
        "anthropic.claude-sonnet-4-20250514-v1:0",
        "anthropic.claude-opus-4-20250514-v1:0",
        "anthropic.claude-3-5-haiku-20241022-v1:0",
    })
end

--- Async preflight check. Verifies the bearer token is available.
---@param provider_config? table
---@param callback? fun(ok: boolean, err?: string)
function M.preflight(provider_config, callback)
    local token = (provider_config or {}).bearer_token or vim.env.AWS_BEARER_TOKEN_BEDROCK
    if not token or token == "" then
        local msg = "[ai-chat] Bedrock bearer token not set. Set AWS_BEARER_TOKEN_BEDROCK env var."
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

--- Send a chat request with streaming via Bedrock InvokeModelWithResponseStream.
---@param messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param callbacks AiChatCallbacks
---@return CancelFn
function M.chat(messages, opts, callbacks)
    local provider_config = opts.provider_config or {}
    local token = provider_config.bearer_token or vim.env.AWS_BEARER_TOKEN_BEDROCK
    local region = provider_config.region or vim.env.AWS_REGION or "us-east-1"

    if not token or token == "" then
        vim.schedule(function()
            callbacks.on_error({
                code = "auth",
                message = "No Bedrock bearer token. Set AWS_BEARER_TOKEN_BEDROCK env var.",
            })
        end)
        return function() end
    end

    local model = opts.model or provider_config.model or "anthropic.claude-sonnet-4-20250514-v1:0"
    local api_model = codec.apply_region_prefix(model, region)
    local endpoint = string.format(
        "https://bedrock-runtime.%s.amazonaws.com/model/%s/invoke-with-response-stream",
        region,
        codec.url_encode_model(api_model)
    )

    local body = codec.build_anthropic_body(messages, opts, provider_config)
    local body_json = vim.json.encode(body)
    local tmpfile = vim.fn.tempname()
    vim.fn.writefile({ body_json }, tmpfile)

    -- Streaming state
    local accumulated_text = ""
    local usage = { input_tokens = 0, output_tokens = 0 }
    local errored = false
    local stream_buffer = ""

    local handle = vim.system({
        "curl",
        "--no-buffer",
        "-s",
        "--connect-timeout",
        "10",
        "-H",
        "Content-Type: application/json",
        "-H",
        "Authorization: Bearer " .. token,
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
                            message = "Bedrock connection failed: "
                                .. tostring(err)
                                .. " Check your network connection and AWS region configuration.",
                        })
                    end)
                end
                return
            end

            if not data or data == "" then
                return
            end

            stream_buffer = stream_buffer .. data

            -- Parse event{...} frames from the stream.
            -- Bedrock InvokeModelWithResponseStream wraps each Anthropic event
            -- in a frame: event{"bytes":"<base64-encoded JSON>"}
            -- Exceptions arrive as: exception{"message":"error text"}
            codec.decode_bedrock_frames(
                stream_buffer,
                callbacks,
                function(text)
                    accumulated_text = accumulated_text .. text
                end,
                usage,
                function()
                    errored = true
                end
            )

            -- Trim processed content: keep only from the last unmatched position.
            -- Since %b{} is greedy and we process all matches, we can clear
            -- the buffer of processed data by finding the last closing brace
            -- position of matched events.
            local last_pos = 0
            for _ in stream_buffer:gmatch("event(%b{})") do
                -- Find position after this match
                local s, e = stream_buffer:find("event%b{}", last_pos + 1)
                if e then
                    last_pos = e
                end
            end
            for _ in stream_buffer:gmatch("exception(%b{})") do
                local s, e = stream_buffer:find("exception%b{}", last_pos + 1)
                if e then
                    last_pos = e
                end
            end
            if last_pos > 0 then
                stream_buffer = stream_buffer:sub(last_pos + 1)
            end
        end,
    }, function(result)
        pcall(vim.fn.delete, tmpfile)

        if errored then
            return
        end

        vim.schedule(function()
            if result.code ~= 0 then
                local err_msg = "Bedrock request failed (curl exit " .. result.code .. ")"
                if result.stderr and result.stderr ~= "" then
                    err_msg = err_msg .. ": " .. result.stderr:sub(1, 200)
                end
                callbacks.on_error({
                    code = "network",
                    message = err_msg,
                })
                return
            end

            -- If we got no text, check for JSON error response
            if accumulated_text == "" and stream_buffer ~= "" then
                local ok, err_data = pcall(vim.json.decode, stream_buffer)
                if ok and err_data and (err_data.message or err_data.Message) then
                    local err_msg = err_data.message or err_data.Message
                    local err_code = "server"
                    if
                        err_msg:match("[Aa]ccess")
                        or err_msg:match("[Uu]nauthorized")
                        or err_msg:match("[Ff]orbidden")
                    then
                        err_code = "auth"
                        err_msg = "Access denied. Check that AWS_BEARER_TOKEN_BEDROCK is set and not expired."
                    elseif err_msg:match("[Tt]hrottle") or err_msg:match("[Rr]ate") then
                        err_code = "rate_limit"
                    elseif err_msg:match("[Mm]odel") and err_msg:match("[Nn]ot [Ff]ound") then
                        err_code = "model_not_found"
                    elseif err_msg:match("[Vv]alidation") then
                        err_code = "invalid_request"
                    end
                    callbacks.on_error({
                        code = err_code,
                        message = err_msg,
                    })
                    return
                end
            end

            callbacks.on_done({
                content = accumulated_text,
                usage = usage,
                model = model,
            })
        end)
    end)

    return function()
        pcall(vim.fn.delete, tmpfile)
        if handle then
            handle:kill("sigterm")
        end
    end
end

return M
