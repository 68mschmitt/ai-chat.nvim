--- ai-chat.nvim — OpenAI Plus/Pro subscription provider
--- Uses Codex-style ChatGPT OAuth tokens and routes requests to the ChatGPT
--- Codex backend. This is not the OpenAI API-key provider and does not bill
--- through OpenAI API credits.

local M = {}

local auth = require("ai-chat.auth.openai")
local log = require("ai-chat.util.log")

M.name = "openai_subscription"
M.display_name = "OpenAI Plus/Pro"

local MODEL_METADATA = {
    { id = "gpt-5.5", name = "GPT-5.5", limit = { context = 400000 }, cost = { input = 0, output = 0 } },
    { id = "gpt-5.4", name = "GPT-5.4", limit = { context = 128000 }, cost = { input = 0, output = 0 } },
    { id = "gpt-5.4-mini", name = "GPT-5.4 mini", limit = { context = 128000 }, cost = { input = 0, output = 0 } },
    { id = "gpt-5.3-codex", name = "GPT-5.3 Codex", limit = { context = 128000 }, cost = { input = 0, output = 0 } },
    { id = "gpt-5.2", name = "GPT-5.2", limit = { context = 128000 }, cost = { input = 0, output = 0 } },
}

local DEFAULT_MODEL = MODEL_METADATA[1].id
local MODEL_SET = {}
for _, model in ipairs(MODEL_METADATA) do
    MODEL_SET[model.id] = true
end

local function resolve_model(model, provider_config)
    local requested = model or provider_config.model or DEFAULT_MODEL
    if MODEL_SET[requested] then
        return requested, false
    end
    local fallback = MODEL_SET[provider_config.model] and provider_config.model or DEFAULT_MODEL
    return fallback, requested
end

local function canonical_error(code, message)
    code = code or "server"
    code = tostring(code)
    local lower_message = tostring(message or ""):lower()
    if code == "usage_not_included" then
        return {
            code = "auth",
            message = "ChatGPT Plus/Pro subscription usage is not available for this account/model. Check your plan or switch providers.",
        }
    end
    if code:match("rate") then
        return { code = "rate_limit", message = message or "OpenAI subscription rate limit hit" }
    end
    if code == "unauthorized" or code == "forbidden" or code == "auth" or lower_message:match("unauthorized") then
        return { code = "auth", message = message or "OpenAI subscription authentication failed" }
    end
    if code == "invalid_request" or lower_message:match("store must") then
        return { code = "invalid_request", message = message or "OpenAI subscription request was invalid" }
    end
    if code == "model_not_found" or lower_message:match("model is not supported") then
        return { code = "model_not_found", message = message or "OpenAI subscription model is not supported" }
    end
    return { code = "server", message = message or "OpenAI subscription request failed" }
end

local function split_messages(messages)
    local instructions = nil
    local input = {}
    for _, msg in ipairs(messages) do
        if msg.role == "system" then
            instructions = msg.content
        else
            table.insert(input, { role = msg.role, content = msg.content })
        end
    end
    return instructions, input
end

local function build_body(messages, opts, model)
    local instructions, input = split_messages(messages)
    local body = {
        model = model,
        stream = true,
        store = false,
        input = input,
    }
    if instructions then
        body.instructions = instructions
    end
    -- Deliberately no temperature or max_tokens/maxOutputTokens.
    -- Current ChatGPT/Codex subscription models reject some normal OpenAI API knobs.
    return body
end

local function extract_text(value, depth)
    if depth > 6 then
        return nil
    end
    if type(value) == "string" then
        return value
    end
    if type(value) ~= "table" then
        return nil
    end

    local parts = {}
    for _, item in ipairs(value) do
        local text = extract_text(item, depth + 1)
        if text and text ~= "" then
            parts[#parts + 1] = text
        end
    end
    if #parts > 0 then
        return table.concat(parts, "")
    end

    for _, key in ipairs({ "delta", "text", "output_text" }) do
        if type(value[key]) == "string" and value[key] ~= "" then
            return value[key]
        end
    end

    if type(value.content) == "string" then
        return value.content
    end
    if type(value.content) == "table" then
        local parts = {}
        for _, item in ipairs(value.content) do
            local text = extract_text(item, depth + 1)
            if text and text ~= "" then
                parts[#parts + 1] = text
            end
        end
        if #parts > 0 then
            return table.concat(parts, "")
        end
    end

    for _, key in ipairs({ "item", "part", "message", "response", "output" }) do
        local text = extract_text(value[key], depth + 1)
        if text and text ~= "" then
            return text
        end
    end

    return nil
end

local function apply_usage(obj, usage)
    local src = obj.usage or (obj.response and obj.response.usage)
    if type(src) ~= "table" then
        return
    end
    usage.input_tokens = src.input_tokens or src.prompt_tokens or usage.input_tokens or 0
    usage.output_tokens = src.output_tokens or src.completion_tokens or usage.output_tokens or 0
end

local function handle_event_object(obj, event_name, callbacks, accumulate, usage, mark_errored, set_final_text)
    local typ = obj.type or event_name or ""

    if typ:match("error") or obj.error then
        mark_errored()
        local err = obj.error or obj
        local mapped = canonical_error(err.code or err.type, err.message)
        vim.schedule(function()
            callbacks.on_error(mapped)
        end)
        return
    end

    apply_usage(obj, usage)

    if typ:match("delta") then
        local text = extract_text(obj, 0)
        if text and text ~= "" then
            accumulate(text)
            vim.schedule(function()
                callbacks.on_chunk(text)
            end)
        end
        return
    end

    if typ:match("completed") or typ:match("done") then
        local final_text = extract_text(obj, 0)
        if final_text and final_text ~= "" then
            set_final_text(final_text)
        end
    end
end

local function handle_plain_json_error(buffer, callbacks, mark_errored)
    local trimmed = vim.trim(buffer or "")
    if trimmed == "" then
        return false
    end
    local ok, obj = pcall(vim.json.decode, trimmed)
    if not ok or type(obj) ~= "table" then
        return false
    end
    if obj.detail or obj.error then
        mark_errored()
        local err = obj.error or obj
        local message = err.message or obj.detail or "OpenAI subscription request failed"
        local code = err.code or err.type or message
        local mapped = canonical_error(code, message)
        vim.schedule(function()
            callbacks.on_error(mapped)
        end)
        return true
    end
    return false
end

local function parse_sse(buffer, callbacks, accumulate, usage, mark_errored, set_final_text, flush)
    if flush and handle_plain_json_error(buffer, callbacks, mark_errored) then
        return ""
    end

    local processed_any = false
    while true do
        local event_end = buffer:find("\n\n", 1, true)
        if not event_end then
            break
        end
        processed_any = true
        local block = buffer:sub(1, event_end - 1)
        buffer = buffer:sub(event_end + 2)

        local event_name, payload
        for line in block:gmatch("[^\n]+") do
            line = line:gsub("\r$", "")
            local ev = line:match("^event:%s*(.*)")
            if ev then
                event_name = ev
            end
            local data = line:match("^data:%s*(.*)")
            if data then
                payload = payload and (payload .. "\n" .. data) or data
            end
        end

        if payload and payload ~= "[DONE]" then
            local ok, obj = pcall(vim.json.decode, payload)
            if ok and type(obj) == "table" then
                handle_event_object(obj, event_name, callbacks, accumulate, usage, mark_errored, set_final_text)
            else
                log.debug("OpenAI subscription: unparsed SSE payload", payload)
            end
        end
    end

    -- Some Codex responses are line-delimited `data: {...}` without blank-line SSE separators.
    if flush or (not processed_any and buffer:find("\n", 1, true)) then
        local remainder = {}
        for line in buffer:gmatch("([^\n]*)\n?") do
            if line ~= "" then
                local payload = line:gsub("\r$", ""):match("^data:%s*(.*)") or line
                if payload ~= "[DONE]" then
                    local ok, obj = pcall(vim.json.decode, payload)
                    if ok and type(obj) == "table" then
                        handle_event_object(obj, nil, callbacks, accumulate, usage, mark_errored, set_final_text)
                    elseif not flush then
                        remainder[#remainder + 1] = line
                    else
                        log.debug("OpenAI subscription: unparsed stream line", line)
                    end
                end
            end
        end
        buffer = table.concat(remainder, "\n")
    end

    return buffer
end

function M.validate(_config)
    if not auth.is_authenticated() then
        return false, "OpenAI Plus/Pro not authenticated. Run :AiChatAuthLogin."
    end
    return true
end

function M.preflight(_provider_config, callback)
    if not auth.is_authenticated() then
        local msg = "[ai-chat] OpenAI Plus/Pro not authenticated. Run :AiChatAuthLogin."
        vim.notify(msg, vim.log.levels.WARN)
        if callback then
            callback(false, msg)
        end
        return
    end
    if callback then
        callback(true)
    end
end

function M.list_models(_config, callback)
    local ids = {}
    for _, model in ipairs(MODEL_METADATA) do
        ids[#ids + 1] = model.id
    end
    callback(ids)
end

function M.model_metadata()
    return vim.deepcopy(MODEL_METADATA)
end

function M.auth_methods(_provider_config)
    return { "browser", "headless" }
end

function M.auth_login(provider_config, opts, callback)
    local method = (opts and opts.method) or "browser"
    if method == "headless" then
        auth.headless_login(provider_config or {}, callback)
    else
        auth.browser_login(provider_config or {}, callback)
    end
end

function M.auth_status(_provider_config)
    local current = auth.get()
    local authenticated = auth.is_authenticated()
    local expires = current and current.expires or nil
    local status = {
        supported = true,
        authenticated = authenticated,
        message = authenticated and "OpenAI Plus/Pro OAuth token found" or "OpenAI Plus/Pro not authenticated",
        account_id = current and current.accountId or nil,
        expires = expires,
    }
    if authenticated and (not current.accountId or current.accountId == "") then
        status.warning = "OpenAI ChatGPT account ID missing; requests will omit the account header"
    end
    if authenticated and expires and expires < os.time() * 1000 then
        status.expired = true
    end
    return status
end

function M.health(provider_config, context)
    local status = M.auth_status(provider_config)
    if status.authenticated then
        vim.health.ok(status.message)
        if status.account_id then
            vim.health.ok("OpenAI ChatGPT account ID found")
        elseif status.warning then
            vim.health.warn(status.warning, { "Run :AiChatAuthLogin to refresh account metadata" })
        end
        if status.expired then
            vim.health.warn("OpenAI Plus/Pro access token expired", { "It will be refreshed on next request" })
        end
    else
        local level = context and context.is_default and "error" or "info"
        vim.health[level](status.message, { "Run :AiChatAuthLogin" })
    end
end

function M.chat(messages, opts, callbacks)
    local provider_config = opts.provider_config or {}
    local endpoint = provider_config.codex_endpoint or "https://chatgpt.com/backend-api/codex/responses"
    local cancelled = false
    local handle = nil
    local tmpfile = nil
    local accumulated = ""
    local final_text = nil
    local raw_preview = ""
    local usage = { input_tokens = 0, output_tokens = 0 }
    local errored = false
    local terminal_fired = false
    local stream_buffer = ""

    local guarded_callbacks = {
        on_chunk = function(text)
            if cancelled or terminal_fired then
                return
            end
            callbacks.on_chunk(text)
        end,
        on_error = function(err)
            if cancelled or terminal_fired then
                return
            end
            terminal_fired = true
            callbacks.on_error(err)
        end,
        on_done = function(response)
            if cancelled or terminal_fired then
                return
            end
            terminal_fired = true
            callbacks.on_done(response)
        end,
    }

    auth.ensure(function(ok, current_auth_or_err)
        if cancelled then
            return
        end
        if not ok then
            guarded_callbacks.on_error({ code = "auth", message = current_auth_or_err })
            return
        end
        local current_auth = current_auth_or_err
        local request_model, unsupported_model = resolve_model(opts.model, provider_config)
        if unsupported_model then
            vim.notify(
                "[ai-chat] OpenAI Plus/Pro model "
                    .. unsupported_model
                    .. " is not supported by Codex; using "
                    .. request_model,
                vim.log.levels.WARN
            )
        end
        local body = vim.json.encode(build_body(messages, opts, request_model))
        tmpfile = vim.fn.tempname()
        vim.fn.writefile({ body }, tmpfile)

        local curl_args = {
            "curl",
            "--no-buffer",
            "-s",
            "--connect-timeout",
            "10",
        }
        local function add_header(header)
            table.insert(curl_args, "-H")
            table.insert(curl_args, header)
        end

        add_header("Content-Type: application/json")
        add_header("Accept: text/event-stream")
        add_header("Authorization: Bearer " .. current_auth.access)
        if current_auth.accountId and current_auth.accountId ~= "" then
            add_header("ChatGPT-Account-Id: " .. current_auth.accountId)
        end
        add_header("originator: " .. (provider_config.auth_originator or "opencode"))
        add_header("session-id: " .. (opts.session_id or "ai-chat"))
        add_header("User-Agent: " .. (provider_config.user_agent or "ai-chat.nvim"))

        table.insert(curl_args, "-d")
        table.insert(curl_args, "@" .. tmpfile)
        table.insert(curl_args, endpoint)

        handle = vim.system(curl_args, {
            stdout = function(err, data)
                if cancelled then
                    return
                end
                if err then
                    errored = true
                    vim.schedule(function()
                        guarded_callbacks.on_error({
                            code = "network",
                            message = "OpenAI subscription connection failed: " .. tostring(err),
                            retryable = true,
                        })
                    end)
                    return
                end
                if not data or data == "" then
                    return
                end
                if #raw_preview < 4000 then
                    raw_preview = raw_preview .. data:sub(1, 4000 - #raw_preview)
                end
                stream_buffer = parse_sse(
                    stream_buffer .. data,
                    guarded_callbacks,
                    function(text)
                        accumulated = accumulated .. text
                    end,
                    usage,
                    function()
                        errored = true
                    end,
                    function(text)
                        final_text = text
                    end,
                    false
                )
            end,
        }, function(result)
            pcall(vim.fn.delete, tmpfile)
            if cancelled or errored then
                return
            end
            stream_buffer = parse_sse(
                stream_buffer,
                guarded_callbacks,
                function(text)
                    accumulated = accumulated .. text
                end,
                usage,
                function()
                    errored = true
                end,
                function(text)
                    final_text = text
                end,
                true
            )
            if errored then
                return
            end
            vim.schedule(function()
                if result.code ~= 0 then
                    guarded_callbacks.on_error({
                        code = "network",
                        message = "OpenAI subscription request failed (curl exit " .. result.code .. ")",
                        retryable = true,
                    })
                    return
                end
                local content = accumulated ~= "" and accumulated or final_text or ""
                if content == "" then
                    log.warn("OpenAI subscription returned no parsed text", {
                        raw_preview = raw_preview,
                        leftover = stream_buffer,
                    })
                    guarded_callbacks.on_error({
                        code = "server",
                        message = "OpenAI subscription returned a response format ai-chat could not parse. Run :AiChatLog and share the raw_preview.",
                    })
                    return
                end
                guarded_callbacks.on_done({
                    content = content,
                    usage = usage,
                    model = request_model,
                })
            end)
        end)
    end)

    return function()
        cancelled = true
        if tmpfile then
            pcall(vim.fn.delete, tmpfile)
        end
        if handle then
            handle:kill("sigterm")
        end
    end
end

return M
