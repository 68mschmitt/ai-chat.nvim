--- ai-chat.nvim — Unsloth Studio provider
--- Local inference through Unsloth Studio's AI API.
--- Supports OpenAI-compatible /v1 endpoints and Studio model API URLs.

local M = {}

M.name = "unsloth_studio"
M.display_name = "Unsloth Studio"

local DEFAULT_BASE_URL = "http://localhost:8000/v1"
local DEFAULT_MODEL = "unsloth"

---@type table<string, string>
local model_url_cache = {}

local function non_empty(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function looks_like_url(value)
    return type(value) == "string" and value:match("^https?://") ~= nil
end

local function strip_trailing_slashes(url)
    return (url or ""):gsub("/+$", "")
end

local function configured_api_key(provider_config)
    return non_empty((provider_config or {}).api_key) or non_empty(vim.env.UNSLOTH_API_KEY)
end

local function configured_base_url(provider_config)
    provider_config = provider_config or {}
    local url = provider_config.endpoint or provider_config.base_url or provider_config.host or DEFAULT_BASE_URL
    url = strip_trailing_slashes(url)
    return url:gsub("/chat/completions$", "")
end

local function models_endpoint(provider_config)
    provider_config = provider_config or {}
    local explicit = provider_config.models_endpoint or provider_config.models_url
    if explicit then
        return strip_trailing_slashes(explicit)
    end
    return configured_base_url(provider_config) .. "/models"
end

local function normalize_explicit_chat_url(url)
    url = strip_trailing_slashes(url)
    if url:match("/v1$") then
        return url .. "/chat/completions"
    end
    return url
end

local function chat_endpoint_from_base(url)
    url = strip_trailing_slashes(url)
    if url:match("/chat/completions$") then
        return url
    end
    return url:gsub("/chat/completions$", "") .. "/chat/completions"
end

local function cache_key(provider_config, model)
    return configured_base_url(provider_config) .. "\n" .. tostring(model or "")
end

local function cached_model_url(provider_config, model)
    if not model then
        return nil
    end
    if looks_like_url(model) then
        return model
    end
    provider_config = provider_config or {}
    if type(provider_config.model_urls) == "table" and provider_config.model_urls[model] then
        return provider_config.model_urls[model]
    end
    return model_url_cache[cache_key(provider_config, model)]
end

local function resolve_chat_endpoint(provider_config, selected_model)
    local model_url = cached_model_url(provider_config, selected_model)
    if model_url then
        return normalize_explicit_chat_url(model_url)
    end

    provider_config = provider_config or {}
    local explicit = provider_config.chat_endpoint or provider_config.chat_url or provider_config.api_url
    if explicit then
        return normalize_explicit_chat_url(explicit)
    end

    return chat_endpoint_from_base(
        provider_config.endpoint or provider_config.base_url or provider_config.host or DEFAULT_BASE_URL
    )
end

local function request_model(provider_config, selected_model)
    provider_config = provider_config or {}
    if looks_like_url(selected_model) then
        return provider_config.model_name or provider_config.model_id or DEFAULT_MODEL
    end
    return selected_model or provider_config.model or DEFAULT_MODEL
end

local function add_auth_header(args, provider_config)
    local api_key = configured_api_key(provider_config)
    if api_key then
        table.insert(args, "-H")
        table.insert(args, "Authorization: Bearer " .. api_key)
    end
end

local function model_list_body(provider_config)
    local body = (provider_config or {}).models_request_body
    if type(body) == "table" then
        local ok, encoded = pcall(vim.json.encode, body)
        if ok then
            return encoded
        end
    elseif type(body) == "string" then
        return body
    end
    return "{}"
end

local function add_model(models, seen, provider_config, id, url)
    id = non_empty(id)
    url = non_empty(url)

    if id and url then
        model_url_cache[cache_key(provider_config, id)] = url
    end
    if url then
        model_url_cache[cache_key(provider_config, url)] = url
    end

    local prefer_url = (provider_config or {}).prefer_model_url ~= false
    local option = (prefer_url and url) or id or url
    if option and not seen[option] then
        seen[option] = true
        table.insert(models, option)
    end
end

local function first_string(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "string" and value ~= "" then
            return value
        end
    end
    return nil
end

local function add_model_entry(models, seen, provider_config, entry, key)
    if type(entry) == "string" then
        if looks_like_url(entry) then
            add_model(models, seen, provider_config, type(key) == "string" and key or nil, entry)
        else
            add_model(models, seen, provider_config, entry, nil)
        end
        return
    end

    if type(entry) ~= "table" then
        return
    end

    local id = first_string(
        entry.id,
        entry.name,
        entry.model,
        entry.model_id,
        entry.slug,
        type(key) == "string" and key or nil
    )
    local url = first_string(
        entry.api_url,
        entry.apiUrl,
        entry.apiURL,
        entry.url,
        entry.endpoint,
        entry.chat_endpoint,
        entry.chatUrl,
        entry.chat_url
    )
    add_model(models, seen, provider_config, id, url)
end

local function collect_models(value, key, models, seen, provider_config)
    if type(value) ~= "table" then
        add_model_entry(models, seen, provider_config, value, key)
        return
    end

    local descended = false
    for _, name in ipairs({ "data", "models", "available_models", "availableModels" }) do
        local container = value[name]
        if type(container) == "table" then
            descended = true
            collect_models(container, nil, models, seen, provider_config)
        end
    end
    if descended then
        return
    end

    local before = #models
    add_model_entry(models, seen, provider_config, value, key)
    if #models > before then
        return
    end

    for child_key, child in pairs(value) do
        collect_models(child, child_key, models, seen, provider_config)
    end
end

local function parse_models(stdout, provider_config)
    if not stdout or stdout == "" then
        return {}
    end
    local ok, data = pcall(vim.json.decode, stdout)
    if not ok or type(data) ~= "table" then
        return {}
    end

    local models = {}
    collect_models(data, nil, models, {}, provider_config or {})
    table.sort(models)
    return models
end

local function fallback_models(provider_config)
    provider_config = provider_config or {}
    local model = non_empty(provider_config.model)
    if model then
        return { model }
    end
    local api_url = non_empty(provider_config.api_url)
        or non_empty(provider_config.chat_endpoint)
        or non_empty(provider_config.chat_url)
    if api_url then
        return { api_url }
    end
    return {}
end

local function fetch_models_once(provider_config, method, callback)
    local args = {
        "curl",
        "-s",
        "--connect-timeout",
        tostring((provider_config or {}).connect_timeout or 3),
    }
    add_auth_header(args, provider_config)

    if method == "POST" then
        table.insert(args, "-X")
        table.insert(args, "POST")
        table.insert(args, "-H")
        table.insert(args, "Content-Type: application/json")
        table.insert(args, "-d")
        table.insert(args, model_list_body(provider_config))
    end

    table.insert(args, models_endpoint(provider_config))

    vim.system(args, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback({})
                return
            end
            callback(parse_models(result.stdout, provider_config))
        end)
    end)
end

local function classify_error(error_value)
    local message
    local error_type
    local error_code

    if type(error_value) == "table" then
        message = error_value.message or error_value.error or "Unsloth Studio API error"
        error_type = error_value.type
        error_code = error_value.code
    else
        message = tostring(error_value or "Unsloth Studio API error")
    end

    local haystack = table.concat({ message or "", error_type or "", error_code or "" }, " "):lower()
    local code = "server"
    if haystack:match("rate") or haystack:match("too many") then
        code = "rate_limit"
    elseif
        haystack:match("auth")
        or haystack:match("api key")
        or haystack:match("unauthorized")
        or haystack:match("forbidden")
    then
        code = "auth"
    elseif haystack:match("model") and haystack:match("not found") then
        code = "model_not_found"
    elseif haystack:match("invalid") or haystack:match("bad request") then
        code = "invalid_request"
    end

    return {
        code = code,
        message = message,
    }
end

local function extract_usage(chunk)
    if type(chunk) ~= "table" then
        return nil
    end
    local usage = chunk.usage or chunk.token_usage
    if type(usage) ~= "table" then
        return nil
    end
    return {
        input_tokens = usage.prompt_tokens or usage.input_tokens or 0,
        output_tokens = usage.completion_tokens or usage.output_tokens or 0,
    }
end

local function extract_text(chunk)
    if type(chunk) ~= "table" then
        return nil
    end
    if chunk.choices and chunk.choices[1] then
        local choice = chunk.choices[1]
        if choice.delta and choice.delta.content then
            return choice.delta.content
        end
        if choice.message and choice.message.content then
            return choice.message.content
        end
        if choice.text then
            return choice.text
        end
    end
    return chunk.response or chunk.content or chunk.text
end

local function emit_error(state, callbacks, err)
    if state.errored then
        return
    end
    state.errored = true
    vim.schedule(function()
        callbacks.on_error(err)
    end)
end

local function handle_payload(payload, state, callbacks)
    if not payload or payload == "" or payload == "[DONE]" then
        return
    end

    local ok, chunk = pcall(vim.json.decode, payload)
    if not ok or type(chunk) ~= "table" then
        return
    end

    if chunk.error or chunk.detail then
        emit_error(state, callbacks, classify_error(chunk.error or chunk.detail))
        return
    end

    local text = extract_text(chunk)
    if text and text ~= "" then
        state.accumulated = state.accumulated .. text
        vim.schedule(function()
            callbacks.on_chunk(text)
        end)
    end

    local usage = extract_usage(chunk)
    if usage then
        state.usage = usage
    end
end

local function handle_stdout(data, state, callbacks)
    state.raw = state.raw .. data
    state.sse_buffer = state.sse_buffer .. data

    while true do
        local line_end = state.sse_buffer:find("\n")
        if not line_end then
            break
        end

        local line = state.sse_buffer:sub(1, line_end - 1):gsub("\r$", "")
        state.sse_buffer = state.sse_buffer:sub(line_end + 1)

        if line ~= "" and not line:match("^event:") then
            local payload = line:match("^data:%s*(.*)") or line:match("^%s*({.*})%s*$")
            handle_payload(payload, state, callbacks)
        end
    end
end

local function parse_full_response(state, callbacks)
    if state.accumulated ~= "" or state.raw == "" then
        return true
    end

    local ok, chunk = pcall(vim.json.decode, state.raw)
    if not ok or type(chunk) ~= "table" then
        return true
    end

    if chunk.error or chunk.detail then
        callbacks.on_error(classify_error(chunk.error or chunk.detail))
        return false
    end

    local text = extract_text(chunk)
    if text then
        state.accumulated = text
    end

    local usage = extract_usage(chunk)
    if usage then
        state.usage = usage
    end

    return true
end

---@param provider_config table
---@return boolean ok
---@return string? error_message
function M.validate(provider_config)
    provider_config = provider_config or {}
    local endpoint = provider_config.endpoint
        or provider_config.base_url
        or provider_config.host
        or provider_config.api_url
    if endpoint ~= nil and type(endpoint) ~= "string" then
        return false, "Unsloth Studio endpoint must be a string."
    end
    return true
end

---@param provider_config table
---@param callback fun(models: string[])
function M.list_models(provider_config, callback)
    provider_config = provider_config or {}
    local method = provider_config.models_method and provider_config.models_method:upper()

    if method == "POST" then
        fetch_models_once(provider_config, "POST", function(models)
            callback(#models > 0 and models or fallback_models(provider_config))
        end)
        return
    elseif method == "GET" then
        fetch_models_once(provider_config, "GET", function(models)
            callback(#models > 0 and models or fallback_models(provider_config))
        end)
        return
    end

    fetch_models_once(provider_config, "GET", function(models)
        if #models > 0 then
            callback(models)
            return
        end
        -- Some Unsloth Studio builds expose discovery behind POST-only routes.
        fetch_models_once(provider_config, "POST", function(post_models)
            callback(#post_models > 0 and post_models or fallback_models(provider_config))
        end)
    end)
end

--- Async preflight check. Verifies the local Studio API is reachable.
---@param provider_config? table
---@param callback? fun(ok: boolean, err?: string)
function M.preflight(provider_config, callback)
    provider_config = provider_config or {}
    local url = normalize_explicit_chat_url(provider_config.api_url or configured_base_url(provider_config))
    vim.system({ "curl", "-s", "--connect-timeout", "2", url }, {}, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                local msg = "[ai-chat] Unsloth Studio not reachable at "
                    .. url
                    .. ". Start Unsloth Studio or set providers.unsloth_studio.endpoint/api_url."
                vim.notify(msg, vim.log.levels.WARN)
                if callback then
                    callback(false, msg)
                end
            elseif callback then
                callback(true)
            end
        end)
    end)
end

function M.health(provider_config, context)
    if not (context and context.is_default) then
        return
    end

    provider_config = provider_config or {}
    local url = normalize_explicit_chat_url(provider_config.api_url or configured_base_url(provider_config))
    local result = vim.system({ "curl", "-s", "--connect-timeout", "3", url }, { text = true }):wait()

    if result.code == 0 then
        vim.health.ok("Unsloth Studio reachable at " .. url)
    else
        vim.health.warn("Unsloth Studio not reachable at " .. url, {
            "Start Unsloth Studio's local AI API",
            "Or configure providers.unsloth_studio.endpoint/api_url with the URL shown by Studio",
        })
    end
end

--- Send a chat request with streaming.
---@param messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param callbacks AiChatCallbacks
---@return CancelFn
function M.chat(messages, opts, callbacks)
    opts = opts or {}
    local provider_config = opts.provider_config or {}
    local selected_model = opts.model or provider_config.model or DEFAULT_MODEL
    local endpoint = resolve_chat_endpoint(provider_config, selected_model)

    local body_table = {
        model = request_model(provider_config, selected_model),
        messages = messages,
        temperature = opts.temperature or provider_config.temperature or 0.7,
        max_tokens = opts.max_tokens or provider_config.max_tokens or 4096,
        stream = provider_config.stream ~= false,
    }

    if provider_config.stream_options then
        body_table.stream_options = provider_config.stream_options
    elseif provider_config.include_usage then
        body_table.stream_options = { include_usage = true }
    end

    local body = vim.json.encode(body_table)
    local tmpfile = vim.fn.tempname()
    vim.fn.writefile({ body }, tmpfile)

    local state = {
        accumulated = "",
        usage = { input_tokens = 0, output_tokens = 0 },
        errored = false,
        sse_buffer = "",
        raw = "",
    }

    local args = {
        "curl",
        "--no-buffer",
        "-s",
        "--connect-timeout",
        tostring(provider_config.connect_timeout or 10),
        "-H",
        "Content-Type: application/json",
    }
    add_auth_header(args, provider_config)
    table.insert(args, "-d")
    table.insert(args, "@" .. tmpfile)
    table.insert(args, endpoint)

    local handle = vim.system(args, {
        stdout = function(err, data)
            if err then
                emit_error(state, callbacks, {
                    code = "network",
                    message = "Unsloth Studio connection failed: "
                        .. tostring(err)
                        .. ". Check that Studio is running and the API URL is correct.",
                    retryable = true,
                })
                return
            end

            if data and data ~= "" then
                handle_stdout(data, state, callbacks)
            end
        end,
    }, function(result)
        pcall(vim.fn.delete, tmpfile)

        if state.errored then
            return
        end

        vim.schedule(function()
            if result.code ~= 0 then
                callbacks.on_error({
                    code = "network",
                    message = "Unsloth Studio request failed (curl exit "
                        .. result.code
                        .. "). Check that Studio is running and the API URL is correct.",
                    retryable = true,
                })
                return
            end

            if not parse_full_response(state, callbacks) then
                return
            end

            callbacks.on_done({
                content = state.accumulated,
                usage = state.usage,
                model = selected_model,
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
