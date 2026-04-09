--- ai-chat.nvim — Bedrock wire format codec
--- Encodes Anthropic Messages API requests for Bedrock's InvokeModelWithResponseStream
--- and decodes the two-layer response format (event{} frames containing Base64-encoded
--- Anthropic JSON payloads). Pure functions — no HTTP, no side effects beyond callbacks.

local M = {}

--- URL-encode a model ID for use in the endpoint path.
--- Bedrock model IDs contain colons (e.g., "...v1:0") which must be encoded.
---@param model string
---@return string
function M.url_encode_model(model)
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
function M.apply_region_prefix(model, region)
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
function M.build_anthropic_body(messages, opts, provider_config)
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

    if opts.thinking then
        local budget = provider_config.thinking_budget or 10000
        body.thinking = {
            type = "enabled",
            budget_tokens = budget,
        }
        body.anthropic_beta = { "interleaved-thinking-2025-05-14" }
    end

    return body
end

--- Process the stream buffer, extracting event{...} and exception{...} frames.
--- Each event contains a Base64-encoded "bytes" field that decodes to
--- standard Anthropic Messages API JSON (content_block_delta, message_start, etc).
---@param buffer string         Raw stream data
---@param callbacks AiChatCallbacks
---@param accumulate fun(text: string)
---@param usage table
---@param mark_errored fun()
---@param thinking_acc table    Thinking accumulator { text = "", current_block_type = nil }
function M.decode_bedrock_frames(buffer, callbacks, accumulate, usage, mark_errored, thinking_acc)
    -- Extract event frames: event{"bytes":"base64data..."}
    for event_json in buffer:gmatch("event(%b{})") do
        local ok, frame = pcall(vim.json.decode, event_json)
        if ok and frame and frame.bytes then
            -- Decode the Base64 payload to get Anthropic-format JSON
            local decode_ok, decoded = pcall(vim.base64.decode, frame.bytes)
            if decode_ok and decoded then
                local json_ok, event = pcall(vim.json.decode, decoded)
                if json_ok and event then
                    M.dispatch_event(event, callbacks, accumulate, usage, mark_errored, thinking_acc)
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
            local err_code = "server"
            if err_msg:match("[Tt]hrottle") or err_msg:match("[Rr]ate") or err_msg:match("[Qq]uota") then
                err_code = "rate_limit"
            elseif err_msg:match("[Tt]imeout") then
                err_code = "timeout"
            elseif err_msg:match("[Aa]ccess") or err_msg:match("[Ff]orbidden") then
                err_code = "auth"
            end
            vim.schedule(function()
                callbacks.on_error({
                    code = err_code,
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
---@param thinking_acc table    Thinking accumulator { text = "", current_block_type = nil }
function M.dispatch_event(event, callbacks, accumulate, usage, mark_errored, thinking_acc)
    local event_type = event.type

    if event_type == "content_block_delta" then
        local delta = event.delta
        if delta and delta.type == "text_delta" and delta.text then
            accumulate(delta.text)
            vim.schedule(function()
                callbacks.on_chunk(delta.text)
            end)
        elseif delta and delta.type == "thinking_delta" and delta.thinking then
            thinking_acc.text = thinking_acc.text .. delta.thinking
            vim.schedule(function()
                callbacks.on_chunk(delta.thinking)
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
        -- Track the current block type for thinking mode
        thinking_acc.current_block_type = event.content_block and event.content_block.type or nil
        if thinking_acc.current_block_type == "thinking" then
            vim.schedule(function()
                callbacks.on_chunk("<thinking>\n")
            end)
        end
    elseif event_type == "content_block_stop" then
        -- Emit closing tag for thinking blocks
        if thinking_acc.current_block_type == "thinking" then
            vim.schedule(function()
                callbacks.on_chunk("\n</thinking>\n")
            end)
        end
        thinking_acc.current_block_type = nil
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
