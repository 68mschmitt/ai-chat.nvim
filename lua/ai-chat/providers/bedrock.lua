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

--- URL-encode a model ID for use in the endpoint path.
--- Bedrock model IDs contain colons (e.g., "...v1:0") which must be encoded.
---@param model string
---@return string
local function url_encode_model(model)
    return model:gsub("([^%w%-_.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

--- Known region prefixes. If a model ID already starts with one of these,
--- skip prefixing — the user (or models.dev) already specified it.
local REGION_PREFIXES = { "us%.", "eu%.", "ap%.", "jp%.", "apac%.", "au%.", "global%." }

--- Models that support cross-region inference profiles (prefix required).
--- Matched as Lua patterns against the model ID.
local CROSS_REGION_MODELS = {
    "anthropic%.claude",
    "amazon%.nova",
    "deepseek",
    "meta%.llama",
    "mistral",
}

--- Apply a region-based prefix to a Bedrock model ID at call time.
--- Following the OpenCode convention: us-* regions get "us." prefix,
--- eu-* get "eu.", ap-northeast-1 gets "jp.", ap-southeast-2 gets "au.",
--- other ap-* gets "apac.". Only applied to known cross-region models.
---@param model string   Base model ID (e.g., "anthropic.claude-sonnet-4-20250514-v1:0")
---@param region string  AWS region (e.g., "us-east-1")
---@return string  The (possibly prefixed) model ID for the API call
local function apply_region_prefix(model, region)
    -- Skip if already prefixed
    for _, prefix_pat in ipairs(REGION_PREFIXES) do
        if model:match("^" .. prefix_pat) then
            return model
        end
    end

    -- Skip if model doesn't support cross-region inference
    local supports_prefix = false
    for _, pat in ipairs(CROSS_REGION_MODELS) do
        if model:match(pat) then
            supports_prefix = true
            break
        end
    end
    if not supports_prefix then
        return model
    end

    -- Apply prefix based on region
    if region:match("^us%-") and not region:match("gov") then
        return "us." .. model
    elseif region:match("^eu%-") then
        return "eu." .. model
    elseif region == "ap-northeast-1" then
        return "jp." .. model
    elseif region == "ap-southeast-2" then
        return "au." .. model
    elseif region:match("^ap%-") then
        return "apac." .. model
    end

    return model
end

--- Build the Anthropic Messages API request body for Bedrock.
--- Uses the native Anthropic format with bedrock-specific anthropic_version.
---@param messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param provider_config table
---@return table body
local function build_anthropic_body(messages, opts, provider_config)
    local system_prompt = nil
    local api_messages = {}

    for _, msg in ipairs(messages) do
        if msg.role == "system" then
            system_prompt = msg.content
        else
            table.insert(api_messages, {
                role = msg.role,
                content = msg.content,
            })
        end
    end

    local body = {
        anthropic_version = "bedrock-2023-05-31",
        max_tokens = opts.max_tokens or provider_config.max_tokens or 8192,
        messages = api_messages,
    }

    if opts.temperature and not opts.thinking then
        body.temperature = opts.temperature
    end

    if system_prompt then
        body.system = system_prompt
    end

    return body
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
    local api_model = apply_region_prefix(model, region)
    local endpoint = string.format(
        "https://bedrock-runtime.%s.amazonaws.com/model/%s/invoke-with-response-stream",
        region,
        url_encode_model(api_model)
    )

    local body = build_anthropic_body(messages, opts, provider_config)
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
            M._decode_bedrock_frames(
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

--- Process the stream buffer, extracting event{...} and exception{...} frames.
--- Each event contains a Base64-encoded "bytes" field that decodes to
--- standard Anthropic Messages API JSON (content_block_delta, message_start, etc).
---@param buffer string         Raw stream data
---@param callbacks AiChatCallbacks
---@param accumulate fun(text: string)
---@param usage table
---@param mark_errored fun()
function M._decode_bedrock_frames(buffer, callbacks, accumulate, usage, mark_errored)
    -- Extract event frames: event{"bytes":"base64data..."}
    for event_json in buffer:gmatch("event(%b{})") do
        local ok, frame = pcall(vim.json.decode, event_json)
        if ok and frame and frame.bytes then
            -- Decode the Base64 payload to get Anthropic-format JSON
            local decode_ok, decoded = pcall(vim.base64.decode, frame.bytes)
            if decode_ok and decoded then
                local json_ok, event = pcall(vim.json.decode, decoded)
                if json_ok and event then
                    M._dispatch_event(event, callbacks, accumulate, usage, mark_errored)
                end
            end
        end
    end

    -- Extract exception frames: exception{"message":"error text"}
    for exc_json in buffer:gmatch("exception(%b{})") do
        local ok, exc = pcall(vim.json.decode, exc_json)
        if ok and exc then
            mark_errored()
            local err_msg = exc.message or "Bedrock stream exception"
            vim.schedule(function()
                callbacks.on_error({
                    code = "server",
                    message = err_msg,
                })
            end)
        end
    end
end

--- Handle a decoded Anthropic Messages API event from the Bedrock stream.
--- These are the same event types as the direct Anthropic API:
--- content_block_delta, message_start, message_stop, message_delta, etc.
---@param event table           Decoded Anthropic JSON event
---@param callbacks AiChatCallbacks
---@param accumulate fun(text: string)
---@param usage table
---@param mark_errored fun()
function M._dispatch_event(event, callbacks, accumulate, usage, mark_errored)
    local event_type = event.type

    if event_type == "content_block_delta" then
        local delta = event.delta
        if delta and delta.type == "text_delta" and delta.text then
            accumulate(delta.text)
            vim.schedule(function()
                callbacks.on_chunk(delta.text)
            end)
        end
    elseif event_type == "message_start" then
        -- Extract input token count from the initial message
        if event.message and event.message.usage then
            usage.input_tokens = event.message.usage.input_tokens or 0
        end
    elseif event_type == "message_delta" then
        -- Final usage info
        if event.usage then
            usage.output_tokens = event.usage.output_tokens or 0
        end
    elseif event_type == "message_stop" then
        -- Stream complete — handled by on_exit callback
    elseif event_type == "content_block_start" then
        -- No action needed
    elseif event_type == "content_block_stop" then
        -- No action needed
    elseif event_type == "ping" then
        -- Keep-alive, no action
    elseif event_type == "error" then
        local err_msg = "Bedrock API error"
        if event.error and event.error.message then
            err_msg = event.error.message
        end
        local err_code = "server"
        if event.error and event.error.type == "rate_limit_error" then
            err_code = "rate_limit"
        elseif event.error and event.error.type == "authentication_error" then
            err_code = "auth"
        elseif event.error and event.error.type == "invalid_request_error" then
            err_code = "invalid_request"
        elseif event.error and event.error.type == "not_found_error" then
            err_code = "model_not_found"
        end
        mark_errored()
        vim.schedule(function()
            callbacks.on_error({
                code = err_code,
                message = err_msg,
            })
        end)
    end
end

return M
