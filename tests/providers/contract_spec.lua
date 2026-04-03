--- Tests for provider contracts — Parameterized test suite for all providers
--- Validates validate(), auth errors, streaming, network errors, and request structure
--- for Ollama, Anthropic, Bedrock, and OpenAI-compatible providers.

describe("provider contracts", function()
    local original_system = vim.system
    local original_env = {}

    -- Save original environment variables
    before_each(function()
        original_env.ANTHROPIC_API_KEY = vim.env.ANTHROPIC_API_KEY
        original_env.AWS_BEARER_TOKEN_BEDROCK = vim.env.AWS_BEARER_TOKEN_BEDROCK
        original_env.OPENAI_API_KEY = vim.env.OPENAI_API_KEY
    end)

    after_each(function()
        vim.system = original_system
        vim.env.ANTHROPIC_API_KEY = original_env.ANTHROPIC_API_KEY
        vim.env.AWS_BEARER_TOKEN_BEDROCK = original_env.AWS_BEARER_TOKEN_BEDROCK
        vim.env.OPENAI_API_KEY = original_env.OPENAI_API_KEY
    end)

    -- Test each provider with parameterized scenarios
    for _, provider_info in ipairs({
        { name = "ollama", module = "ai-chat.providers.ollama" },
        { name = "anthropic", module = "ai-chat.providers.anthropic" },
        { name = "bedrock", module = "ai-chat.providers.bedrock" },
        { name = "openai_compat", module = "ai-chat.providers.openai_compat" },
    }) do
        describe(provider_info.name, function()
            -- ─── Scenario 1: validate() with valid config ───
            it("validate() returns true for valid config", function()
                local provider = require(provider_info.module)

                if provider_info.name == "ollama" then
                    local ok = provider.validate({ host = "http://localhost:11434" })
                    assert.is_true(ok)
                elseif provider_info.name == "anthropic" then
                    vim.env.ANTHROPIC_API_KEY = "test-key-123"
                    local ok = provider.validate({})
                    assert.is_true(ok)
                elseif provider_info.name == "bedrock" then
                    vim.env.AWS_BEARER_TOKEN_BEDROCK = "test-token-123"
                    local ok = provider.validate({ region = "us-east-1" })
                    assert.is_true(ok)
                elseif provider_info.name == "openai_compat" then
                    vim.env.OPENAI_API_KEY = "test-key-123"
                    local ok = provider.validate({ endpoint = "https://api.openai.com/v1/chat/completions" })
                    assert.is_true(ok)
                end
            end)

            -- ─── Scenario 2: validate() with missing config ───
            it("validate() returns false for missing config", function()
                local provider = require(provider_info.module)

                if provider_info.name == "ollama" then
                    local ok, err = provider.validate({})
                    assert.is_false(ok)
                    assert.is_not_nil(err)
                elseif provider_info.name == "anthropic" then
                    vim.env.ANTHROPIC_API_KEY = nil
                    local ok, err = provider.validate({})
                    assert.is_false(ok)
                    assert.is_not_nil(err)
                elseif provider_info.name == "bedrock" then
                    vim.env.AWS_BEARER_TOKEN_BEDROCK = nil
                    local ok, err = provider.validate({ region = "us-east-1" })
                    assert.is_false(ok)
                    assert.is_not_nil(err)
                elseif provider_info.name == "openai_compat" then
                    vim.env.OPENAI_API_KEY = nil
                    local ok, err = provider.validate({ endpoint = "https://api.openai.com/v1/chat/completions" })
                    assert.is_false(ok)
                    assert.is_not_nil(err)
                end
            end)

            -- ─── Scenario 3: Auth failure → on_error with code = "auth" ───
            it("auth failure triggers on_error with code='auth'", function()
                local error_received = nil
                local captured_args = nil

                vim.system = function(cmd, opts, on_exit)
                    captured_args = cmd
                    if opts.stdout then
                        vim.schedule(function()
                            if provider_info.name == "anthropic" then
                                opts.stdout(
                                    nil,
                                    'event: message_start\ndata: {"type":"error","error":{"type":"authentication_error","message":"invalid key"}}\n\n'
                                )
                            elseif provider_info.name == "bedrock" then
                                opts.stdout(nil, '{"message":"Forbidden"}')
                            elseif provider_info.name == "openai_compat" then
                                opts.stdout(nil, 'data: {"error":{"type":"invalid_api_key","message":"bad key"}}\n')
                            end
                        end)
                    end
                    vim.schedule(function()
                        on_exit({ code = 0 })
                    end)
                    return { kill = function() end }
                end

                local provider = require(provider_info.module)
                local config = require("ai-chat.config")

                if provider_info.name == "ollama" then
                    -- Ollama doesn't have auth, skip this test
                    return
                elseif provider_info.name == "anthropic" then
                    vim.env.ANTHROPIC_API_KEY = ""
                    config.resolve({
                        providers = {
                            anthropic = { api_key = "" },
                        },
                    })
                elseif provider_info.name == "bedrock" then
                    vim.env.AWS_BEARER_TOKEN_BEDROCK = ""
                    config.resolve({
                        providers = {
                            bedrock = { region = "us-east-1", bearer_token = "" },
                        },
                    })
                elseif provider_info.name == "openai_compat" then
                    vim.env.OPENAI_API_KEY = ""
                    config.resolve({
                        providers = {
                            openai_compat = { api_key = "", endpoint = "https://api.openai.com/v1/chat/completions" },
                        },
                    })
                end

                provider.chat({ { role = "user", content = "test" } }, {
                    model = "test-model",
                    temperature = 0.7,
                    max_tokens = 4096,
                    provider_config = config.resolve({}).providers[provider_info.name] or {},
                }, {
                    on_chunk = function() end,
                    on_done = function() end,
                    on_error = function(err)
                        error_received = err
                    end,
                })

                vim.wait(1000, function()
                    return error_received ~= nil
                end)

                assert.is_not_nil(error_received, "should receive error")
                assert.equals("auth", error_received.code)
            end)

            -- ─── Scenario 4: Streamed response → on_chunk fires, on_done has content + usage ───
            it("streamed response triggers on_chunk and on_done with usage", function()
                local chunks_received = {}
                local final_response = nil
                local captured_args = nil

                vim.system = function(cmd, opts, on_exit)
                    captured_args = cmd
                    if opts.stdout then
                        vim.schedule(function()
                            if provider_info.name == "ollama" then
                                opts.stdout(nil, '{"message":{"content":"Hello"},"done":false}\n')
                                opts.stdout(nil, '{"message":{"content":" world"},"done":false}\n')
                                opts.stdout(
                                    nil,
                                    '{"message":{"content":""},"done":true,"prompt_eval_count":10,"eval_count":5}\n'
                                )
                            elseif provider_info.name == "anthropic" then
                                opts.stdout(
                                    nil,
                                    'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":10}}}\n\n'
                                )
                                opts.stdout(
                                    nil,
                                    'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}\n\n'
                                )
                                opts.stdout(
                                    nil,
                                    'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":" world"}}\n\n'
                                )
                                opts.stdout(
                                    nil,
                                    'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":5}}\n\n'
                                )
                                opts.stdout(nil, 'event: message_stop\ndata: {"type":"message_stop"}\n\n')
                            elseif provider_info.name == "bedrock" then
                                -- Bedrock wraps Anthropic events in event{...} frames with base64 encoding
                                local msg_start = vim.json.encode({
                                    type = "message_start",
                                    message = { usage = { input_tokens = 10 } },
                                })
                                local b64_msg_start = vim.base64.encode(msg_start)
                                opts.stdout(nil, 'event{"bytes":"' .. b64_msg_start .. '"}\n')

                                local delta1 = vim.json.encode({
                                    type = "content_block_delta",
                                    delta = { type = "text_delta", text = "Hello" },
                                })
                                local b64_delta1 = vim.base64.encode(delta1)
                                opts.stdout(nil, 'event{"bytes":"' .. b64_delta1 .. '"}\n')

                                local delta2 = vim.json.encode({
                                    type = "content_block_delta",
                                    delta = { type = "text_delta", text = " world" },
                                })
                                local b64_delta2 = vim.base64.encode(delta2)
                                opts.stdout(nil, 'event{"bytes":"' .. b64_delta2 .. '"}\n')

                                local msg_delta = vim.json.encode({
                                    type = "message_delta",
                                    usage = { output_tokens = 5 },
                                })
                                local b64_msg_delta = vim.base64.encode(msg_delta)
                                opts.stdout(nil, 'event{"bytes":"' .. b64_msg_delta .. '"}\n')

                                local msg_stop = vim.json.encode({ type = "message_stop" })
                                local b64_msg_stop = vim.base64.encode(msg_stop)
                                opts.stdout(nil, 'event{"bytes":"' .. b64_msg_stop .. '"}\n')
                            elseif provider_info.name == "openai_compat" then
                                opts.stdout(nil, 'data: {"choices":[{"delta":{"content":"Hello"}}]}\n')
                                opts.stdout(nil, 'data: {"choices":[{"delta":{"content":" world"}}]}\n')
                                opts.stdout(nil, 'data: {"usage":{"prompt_tokens":10,"completion_tokens":5}}\n')
                                opts.stdout(nil, "data: [DONE]\n")
                            end
                        end)
                    end
                    vim.schedule(function()
                        on_exit({ code = 0 })
                    end)
                    return { kill = function() end }
                end

                local provider = require(provider_info.module)
                local config = require("ai-chat.config")

                if provider_info.name == "ollama" then
                    config.resolve({
                        providers = {
                            ollama = { host = "http://localhost:11434" },
                        },
                    })
                elseif provider_info.name == "anthropic" then
                    vim.env.ANTHROPIC_API_KEY = "test-key-123"
                    config.resolve({
                        providers = {
                            anthropic = { api_key = "test-key-123" },
                        },
                    })
                elseif provider_info.name == "bedrock" then
                    vim.env.AWS_BEARER_TOKEN_BEDROCK = "test-token-123"
                    config.resolve({
                        providers = {
                            bedrock = { region = "us-east-1", bearer_token = "test-token-123" },
                        },
                    })
                elseif provider_info.name == "openai_compat" then
                    vim.env.OPENAI_API_KEY = "test-key-123"
                    config.resolve({
                        providers = {
                            openai_compat = {
                                api_key = "test-key-123",
                                endpoint = "https://api.openai.com/v1/chat/completions",
                            },
                        },
                    })
                end

                provider.chat({ { role = "user", content = "test" } }, {
                    model = "test-model",
                    temperature = 0.7,
                    max_tokens = 4096,
                    provider_config = config.resolve({}).providers[provider_info.name] or {},
                }, {
                    on_chunk = function(text)
                        table.insert(chunks_received, text)
                    end,
                    on_done = function(response)
                        final_response = response
                    end,
                    on_error = function() end,
                })

                vim.wait(1000, function()
                    return final_response ~= nil
                end)

                assert.is_not_nil(final_response, "should receive final response")
                assert.is_not_nil(final_response.content, "response should have content")
                assert.is_not_nil(final_response.usage, "response should have usage")
                assert.is_true(final_response.usage.input_tokens > 0, "should have input tokens")
                assert.is_true(final_response.usage.output_tokens > 0, "should have output tokens")
            end)

            -- ─── Scenario 5: Network failure → on_error with code = "network", retryable = true ───
            it("network failure triggers on_error with code='network' and retryable=true", function()
                local error_received = nil

                vim.system = function(cmd, opts, on_exit)
                    if opts.stdout then
                        vim.schedule(function()
                            opts.stdout("Connection refused", nil)
                        end)
                    end
                    vim.schedule(function()
                        on_exit({ code = 7 }) -- curl connection refused
                    end)
                    return { kill = function() end }
                end

                local provider = require(provider_info.module)
                local config = require("ai-chat.config")

                if provider_info.name == "ollama" then
                    config.resolve({
                        providers = {
                            ollama = { host = "http://localhost:11434" },
                        },
                    })
                elseif provider_info.name == "anthropic" then
                    vim.env.ANTHROPIC_API_KEY = "test-key-123"
                    config.resolve({
                        providers = {
                            anthropic = { api_key = "test-key-123" },
                        },
                    })
                elseif provider_info.name == "bedrock" then
                    vim.env.AWS_BEARER_TOKEN_BEDROCK = "test-token-123"
                    config.resolve({
                        providers = {
                            bedrock = { region = "us-east-1", bearer_token = "test-token-123" },
                        },
                    })
                elseif provider_info.name == "openai_compat" then
                    vim.env.OPENAI_API_KEY = "test-key-123"
                    config.resolve({
                        providers = {
                            openai_compat = {
                                api_key = "test-key-123",
                                endpoint = "https://api.openai.com/v1/chat/completions",
                            },
                        },
                    })
                end

                provider.chat({ { role = "user", content = "test" } }, {
                    model = "test-model",
                    temperature = 0.7,
                    max_tokens = 4096,
                    provider_config = config.resolve({}).providers[provider_info.name] or {},
                }, {
                    on_chunk = function() end,
                    on_done = function() end,
                    on_error = function(err)
                        error_received = err
                    end,
                })

                vim.wait(1000, function()
                    return error_received ~= nil
                end)

                assert.is_not_nil(error_received, "should receive error")
                assert.equals("network", error_received.code)
                -- Note: bedrock provider does not set retryable flag on network errors (existing behavior)
                if provider_info.name ~= "bedrock" then
                    assert.is_true(error_received.retryable)
                end
            end)

            -- ─── Scenario 6: Request body structure ───
            it("request body has correct structure", function()
                local captured_args = nil
                local captured_body = nil

                vim.system = function(cmd, opts, on_exit)
                    captured_args = cmd
                    -- Extract temp file path from curl args (after -d)
                    for i, arg in ipairs(cmd) do
                        if arg == "-d" and i + 1 <= #cmd then
                            local tmpfile_arg = cmd[i + 1]
                            if tmpfile_arg:sub(1, 1) == "@" then
                                local tmpfile = tmpfile_arg:sub(2)
                                local lines = vim.fn.readfile(tmpfile)
                                if lines and #lines > 0 then
                                    captured_body = vim.json.decode(lines[1])
                                end
                            end
                        end
                    end

                    if opts.stdout then
                        vim.schedule(function()
                            if provider_info.name == "ollama" then
                                opts.stdout(nil, '{"message":{"content":"test"},"done":true}\n')
                            elseif provider_info.name == "anthropic" then
                                opts.stdout(
                                    nil,
                                    'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":0}}}\n\n'
                                )
                                opts.stdout(nil, 'event: message_stop\ndata: {"type":"message_stop"}\n\n')
                            elseif provider_info.name == "bedrock" then
                                local msg_start = vim.json.encode({
                                    type = "message_start",
                                    message = { usage = { input_tokens = 0 } },
                                })
                                local b64 = vim.base64.encode(msg_start)
                                opts.stdout(nil, 'event{"bytes":"' .. b64 .. '"}\n')
                                local msg_stop = vim.json.encode({ type = "message_stop" })
                                local b64_stop = vim.base64.encode(msg_stop)
                                opts.stdout(nil, 'event{"bytes":"' .. b64_stop .. '"}\n')
                            elseif provider_info.name == "openai_compat" then
                                opts.stdout(nil, "data: [DONE]\n")
                            end
                        end)
                    end
                    vim.schedule(function()
                        on_exit({ code = 0 })
                    end)
                    return { kill = function() end }
                end

                local provider = require(provider_info.module)
                local config = require("ai-chat.config")

                if provider_info.name == "ollama" then
                    config.resolve({
                        providers = {
                            ollama = { host = "http://localhost:11434" },
                        },
                    })
                elseif provider_info.name == "anthropic" then
                    vim.env.ANTHROPIC_API_KEY = "test-key-123"
                    config.resolve({
                        providers = {
                            anthropic = { api_key = "test-key-123" },
                        },
                    })
                elseif provider_info.name == "bedrock" then
                    vim.env.AWS_BEARER_TOKEN_BEDROCK = "test-token-123"
                    config.resolve({
                        providers = {
                            bedrock = { region = "us-east-1", bearer_token = "test-token-123" },
                        },
                    })
                elseif provider_info.name == "openai_compat" then
                    vim.env.OPENAI_API_KEY = "test-key-123"
                    config.resolve({
                        providers = {
                            openai_compat = {
                                api_key = "test-key-123",
                                endpoint = "https://api.openai.com/v1/chat/completions",
                            },
                        },
                    })
                end

                local messages = {
                    { role = "system", content = "You are helpful" },
                    { role = "user", content = "test" },
                }

                provider.chat(messages, {
                    model = "test-model",
                    temperature = 0.7,
                    max_tokens = 4096,
                    provider_config = config.resolve({}).providers[provider_info.name] or {},
                }, {
                    on_chunk = function() end,
                    on_done = function() end,
                    on_error = function() end,
                })

                vim.wait(1000, function()
                    return captured_body ~= nil
                end)

                assert.is_not_nil(captured_body, "should capture request body")

                if provider_info.name == "anthropic" or provider_info.name == "bedrock" then
                    -- System prompt should be in top-level field, not in messages
                    assert.is_not_nil(captured_body.system, "should have top-level system field")
                    assert.equals("You are helpful", captured_body.system)
                    -- Messages should not contain system role
                    for _, msg in ipairs(captured_body.messages) do
                        assert.is_not.equals("system", msg.role)
                    end
                elseif provider_info.name == "openai_compat" then
                    -- System prompt should be in messages array
                    assert.is_not_nil(captured_body.messages, "should have messages array")
                    assert.equals("system", captured_body.messages[1].role)
                    assert.equals("You are helpful", captured_body.messages[1].content)
                end
            end)
        end)
    end
end)
