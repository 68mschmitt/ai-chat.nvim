--- ai-chat.nvim — OpenAI ChatGPT Plus/Pro OAuth
--- Implements Codex-style OAuth login, device login, token refresh, and auth storage.
--- Does not collect passwords or automate browsers.

local M = {}

local store = require("ai-chat.auth.store")

local CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
local AUTH_URL = "https://auth.openai.com/oauth/authorize"
local TOKEN_URL = "https://auth.openai.com/oauth/token"
local DEVICE_USERCODE_URL = "https://auth.openai.com/api/accounts/deviceauth/usercode"
local DEVICE_URL = "https://auth.openai.com/codex/device"
local ACCOUNT_CHECK_URL = "https://chatgpt.com/backend-api/accounts/check/v4"
local SKEW_MS = 60 * 1000

local function now_ms()
    return os.time() * 1000
end

local function rand_hex(bytes)
    local out = {}
    for _ = 1, bytes do
        out[#out + 1] = string.format("%02x", math.random(0, 255))
    end
    return table.concat(out)
end

local function url_encode(s)
    return tostring(s):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function form_encode(t)
    local parts = {}
    for k, v in pairs(t) do
        parts[#parts + 1] = url_encode(k) .. "=" .. url_encode(v)
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

local function b64url(s)
    return (vim.base64.encode(s):gsub("+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

local function b64url_decode(s)
    s = s:gsub("-", "+"):gsub("_", "/")
    local pad = #s % 4
    if pad > 0 then
        s = s .. string.rep("=", 4 - pad)
    end
    return vim.base64.decode(s)
end

local function sha256_b64url(text)
    local result = vim.system({ "openssl", "dgst", "-sha256", "-binary" }, { stdin = text, text = false }):wait()
    if result.code ~= 0 then
        error("[ai-chat] openssl is required for OpenAI OAuth PKCE")
    end
    return b64url(result.stdout)
end

local function token_claim_account_id(claims)
    if type(claims) ~= "table" then
        return nil
    end
    if type(claims.chatgpt_account_id) == "string" then
        return claims.chatgpt_account_id
    end
    local api_auth = claims["https://api.openai.com/auth"]
    if type(api_auth) == "table" and type(api_auth.chatgpt_account_id) == "string" then
        return api_auth.chatgpt_account_id
    end
    if type(claims.organizations) == "table" and type(claims.organizations[1]) == "table" then
        return claims.organizations[1].id
    end
    return nil
end

local function find_account_id(value, depth)
    if depth > 4 or type(value) ~= "table" then
        return nil
    end

    for _, key in ipairs({
        "chatgpt_account_id",
        "chatgptAccountId",
        "account_id",
        "accountId",
        "organization_id",
        "organizationId",
    }) do
        if type(value[key]) == "string" and value[key] ~= "" then
            return value[key]
        end
    end

    for _, child in pairs(value) do
        local found = find_account_id(child, depth + 1)
        if found then
            return found
        end
    end
    return nil
end

local function extract_account_id(token)
    if not token or token == "" then
        return nil
    end
    local payload = token:match("^[^.]+%.([^.]+)%.")
    if not payload then
        return nil
    end
    local ok_decode, decoded = pcall(b64url_decode, payload)
    if not ok_decode then
        return nil
    end
    local ok_json, claims = pcall(vim.json.decode, decoded)
    if not ok_json or type(claims) ~= "table" then
        return nil
    end
    return token_claim_account_id(claims) or find_account_id(claims, 0)
end

local function exchange_code(code, verifier, redirect_uri, callback)
    local body = form_encode({
        client_id = CLIENT_ID,
        grant_type = "authorization_code",
        code = code,
        code_verifier = verifier,
        redirect_uri = redirect_uri,
    })
    vim.system({
        "curl",
        "-s",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/x-www-form-urlencoded",
        "-d",
        body,
        TOKEN_URL,
    }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(false, "OAuth token exchange failed")
                return
            end
            local ok, data = pcall(vim.json.decode, result.stdout)
            if not ok or type(data) ~= "table" or not data.refresh_token then
                callback(false, "OAuth token exchange returned an invalid response")
                return
            end
            local auth = {
                type = "oauth",
                refresh = data.refresh_token,
                access = data.access_token,
                expires = now_ms() + ((data.expires_in or 3600) * 1000),
                accountId = extract_account_id(data.id_token) or extract_account_id(data.access_token),
            }
            store.set("openai", auth)
            callback(true, auth)
        end)
    end)
end

function M.get()
    return store.get("openai")
end

function M.logout()
    store.delete("openai")
end

function M.is_authenticated()
    local auth = M.get()
    return auth and auth.type == "oauth" and auth.refresh and auth.accountId ~= nil
end

function M.refresh(callback)
    local auth = M.get()
    if not auth or auth.type ~= "oauth" or not auth.refresh then
        callback(false, "OpenAI Plus/Pro is not authenticated")
        return
    end
    local body = form_encode({ client_id = CLIENT_ID, grant_type = "refresh_token", refresh_token = auth.refresh })
    vim.system({
        "curl",
        "-s",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/x-www-form-urlencoded",
        "-d",
        body,
        TOKEN_URL,
    }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(false, "OpenAI token refresh failed")
                return
            end
            local ok, data = pcall(vim.json.decode, result.stdout)
            if not ok or type(data) ~= "table" or not data.access_token then
                callback(false, "OpenAI token refresh returned an invalid response")
                return
            end
            auth.access = data.access_token
            auth.refresh = data.refresh_token or auth.refresh
            auth.expires = now_ms() + ((data.expires_in or 3600) * 1000)
            auth.accountId = extract_account_id(data.id_token)
                or extract_account_id(data.access_token)
                or auth.accountId
            store.set("openai", auth)
            callback(true, auth)
        end)
    end)
end

local function fetch_account_id(current_auth, callback)
    if current_auth.accountId and current_auth.accountId ~= "" then
        callback(true, current_auth)
        return
    end
    if not current_auth.access or current_auth.access == "" then
        callback(true, current_auth)
        return
    end

    vim.system({
        "curl",
        "-s",
        "--connect-timeout",
        "10",
        "-H",
        "Authorization: Bearer " .. current_auth.access,
        ACCOUNT_CHECK_URL,
    }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 or not result.stdout or result.stdout == "" then
                callback(true, current_auth)
                return
            end
            local ok, data = pcall(vim.json.decode, result.stdout)
            if ok and type(data) == "table" then
                local account_id = find_account_id(data, 0)
                if account_id then
                    current_auth.accountId = account_id
                    store.set("openai", current_auth)
                end
            end
            callback(true, current_auth)
        end)
    end)
end

function M.ensure(callback)
    local auth = M.get()
    if not auth or auth.type ~= "oauth" or not auth.refresh then
        callback(
            false,
            "OpenAI Plus/Pro is not authenticated. Run :AiChatOpenAIAuth browser or :AiChatOpenAIAuth headless."
        )
        return
    end
    local function finish(ok, refreshed_or_err)
        if not ok then
            callback(false, refreshed_or_err)
            return
        end
        fetch_account_id(refreshed_or_err, callback)
    end
    if auth.access and auth.expires and auth.expires > now_ms() + SKEW_MS then
        finish(true, auth)
    else
        M.refresh(finish)
    end
end

function M.browser_login(cfg, callback)
    cfg = cfg or {}
    local port = cfg.callback_port or 1455
    local redirect_uri = "http://localhost:" .. port .. "/auth/callback"
    local verifier = b64url(rand_hex(48))
    local challenge = sha256_b64url(verifier)
    local state = rand_hex(16)
    local server = assert((vim.uv or vim.loop).new_tcp())

    server:bind("127.0.0.1", port)
    server:listen(1, function(err)
        if err then
            callback(false, "Failed to listen for OAuth callback: " .. tostring(err))
            return
        end
        local client = (vim.uv or vim.loop).new_tcp()
        server:accept(client)
        client:read_start(function(read_err, data)
            if read_err or not data then
                return
            end
            local path = data:match("GET%s+([^%s]+)%s+HTTP") or ""
            local query = path:match("%?(.*)") or ""
            local params = {}
            for k, v in query:gmatch("([^&=?]+)=([^&=?]+)") do
                params[k] = vim.uri_decode(v)
            end
            local ok_state = params.state == state
            local code = params.code
            local response = ok_state and code and "OpenAI auth complete. You can close this tab."
                or "OpenAI auth failed. Return to Neovim."
            client:write(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: " .. #response .. "\r\n\r\n" .. response
            )
            client:shutdown(function()
                client:close()
                server:close()
            end)
            if not ok_state or not code then
                vim.schedule(function()
                    callback(false, "OAuth callback state mismatch or missing code")
                end)
                return
            end
            exchange_code(code, verifier, redirect_uri, callback)
        end)
    end)

    local auth_url = AUTH_URL
        .. "?"
        .. form_encode({
            client_id = CLIENT_ID,
            response_type = "code",
            redirect_uri = redirect_uri,
            scope = "openid profile email offline_access",
            code_challenge = challenge,
            code_challenge_method = "S256",
            state = state,
            id_token_add_organizations = "true",
            codex_cli_simplified_flow = "true",
            originator = cfg.auth_originator or "opencode",
        })
    vim.fn.jobstart({ "xdg-open", auth_url }, { detach = true })
    vim.notify("[ai-chat] OpenAI login opened in browser", vim.log.levels.INFO)
end

function M.headless_login(cfg, callback)
    cfg = cfg or {}
    local body = vim.json.encode({ client_id = CLIENT_ID })
    vim.system({
        "curl",
        "-s",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-d",
        body,
        DEVICE_USERCODE_URL,
    }, { text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(false, "OpenAI device login failed")
                return
            end
            local ok, data = pcall(vim.json.decode, result.stdout)
            if not ok or type(data) ~= "table" then
                callback(false, "OpenAI device login returned an invalid response")
                return
            end
            local user_code = data.user_code or data.userCode or data.code
            local device_auth_id = data.device_auth_id or data.deviceAuthId
            local device_code = data.device_code or data.deviceCode or device_auth_id
            local interval = data.interval or 5
            local expires_in = data.expires_in or 900
            vim.notify(
                "[ai-chat] Visit " .. DEVICE_URL .. " and enter code: " .. tostring(user_code),
                vim.log.levels.INFO
            )

            local started = now_ms()
            local timer = (vim.uv or vim.loop).new_timer()
            timer:start(
                0,
                interval * 1000,
                vim.schedule_wrap(function()
                    if now_ms() - started > expires_in * 1000 then
                        timer:stop()
                        timer:close()
                        callback(false, "OpenAI device login expired")
                        return
                    end
                    local poll_body = vim.json.encode({
                        device_auth_id = device_auth_id or device_code,
                        user_code = user_code,
                    })
                    vim.system({
                        "curl",
                        "-s",
                        "-X",
                        "POST",
                        "-H",
                        "Content-Type: application/json",
                        "-d",
                        poll_body,
                        "https://auth.openai.com/api/accounts/deviceauth/token",
                    }, { text = true }, function(poll)
                        vim.schedule(function()
                            if poll.code ~= 0 then
                                return
                            end
                            local poll_ok, poll_data = pcall(vim.json.decode, poll.stdout)
                            if not poll_ok or type(poll_data) ~= "table" then
                                return
                            end
                            local code = poll_data.authorization_code or poll_data.authorizationCode or poll_data.code
                            local verifier = poll_data.code_verifier
                                or poll_data.codeVerifier
                                or data.code_verifier
                                or data.codeVerifier
                                or ""
                            if code then
                                timer:stop()
                                timer:close()
                                exchange_code(
                                    code,
                                    verifier,
                                    AUTH_URL:gsub("/oauth/authorize$", "/deviceauth/callback"),
                                    callback
                                )
                            end
                        end)
                    end)
                end)
            )
        end)
    end)
end

return M
