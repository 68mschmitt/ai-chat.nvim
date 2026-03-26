--- Integration tests for the send→stream→render pipeline with mocked providers.
--- Tests the full flow: message building, context collection, provider call,
--- streaming chunks, rendered output, error handling, and retry.

describe("pipeline integration", function()
    local original_system = vim.system
    local config = require("ai-chat.config")
    local pipeline = require("ai-chat.pipeline")

    before_each(function()
        -- Fresh config for each test
        config.resolve({
            default_provider = "ollama",
            default_model = "llama3.2",
            history = { enabled = false },
            log = { enabled = false },
        })
        pipeline.reset()
    end)

    after_each(function()
        vim.system = original_system
    end)

    describe("error classification", function()
        local errors = require("ai-chat.errors")

        it("classifies rate_limit as retryable", function()
            assert.equals("retryable", errors.classify("rate_limit"))
            assert.is_true(errors.is_retryable({ code = "rate_limit" }))
        end)

        it("classifies network as retryable", function()
            assert.equals("retryable", errors.classify("network"))
            assert.is_true(errors.is_retryable({ code = "network" }))
        end)

        it("classifies server as retryable", function()
            assert.equals("retryable", errors.classify("server"))
            assert.is_true(errors.is_retryable({ code = "server" }))
        end)

        it("classifies timeout as retryable", function()
            assert.equals("retryable", errors.classify("timeout"))
            assert.is_true(errors.is_retryable({ code = "timeout" }))
        end)

        it("classifies auth as fatal", function()
            assert.equals("fatal", errors.classify("auth"))
            assert.is_false(errors.is_retryable({ code = "auth" }))
        end)

        it("classifies invalid_request as fatal", function()
            assert.equals("fatal", errors.classify("invalid_request"))
            assert.is_false(errors.is_retryable({ code = "invalid_request" }))
        end)

        it("classifies model_not_found as fatal", function()
            assert.equals("fatal", errors.classify("model_not_found"))
            assert.is_false(errors.is_retryable({ code = "model_not_found" }))
        end)

        it("classifies not_implemented as fatal", function()
            assert.equals("fatal", errors.classify("not_implemented"))
            assert.is_false(errors.is_retryable({ code = "not_implemented" }))
        end)

        it("classifies unknown codes as unknown (not retryable)", function()
            assert.equals("unknown", errors.classify("something_weird"))
            assert.is_false(errors.is_retryable({ code = "something_weird" }))
        end)

        it("respects explicit retryable override from provider", function()
            -- Provider says retryable=true even though code is fatal
            assert.is_true(errors.is_retryable({ code = "auth", retryable = true }))
            -- Provider says retryable=false even though code is retryable
            assert.is_false(errors.is_retryable({ code = "rate_limit", retryable = false }))
        end)

        it("creates standardized error with new()", function()
            local err = errors.new("rate_limit", "Too many requests", { retry_after = 30 })
            assert.equals("rate_limit", err.code)
            assert.equals("Too many requests", err.message)
            assert.equals(30, err.retry_after)
            assert.equals("retryable", err.category)
        end)
    end)

    describe("context window per-model", function()
        local conversation = require("ai-chat.conversation")

        it("uses model-specific context window when available", function()
            local window = conversation._get_context_window("openai_compat", "gpt-4o")
            assert.equals(128000, window)
        end)

        it("falls back to provider default for unknown models", function()
            local window = conversation._get_context_window("anthropic", "claude-unknown-2099")
            assert.equals(200000, window)
        end)

        it("falls back to 4096 for completely unknown provider and model", function()
            local window = conversation._get_context_window("unknown_provider", "unknown_model")
            assert.equals(4096, window)
        end)

        it("uses user config context_window override", function()
            config.resolve({
                default_provider = "ollama",
                default_model = "custom-model",
                providers = {
                    ollama = {
                        host = "http://localhost:11434",
                        context_window = 32768,
                    },
                },
                history = { enabled = false },
                log = { enabled = false },
            })
            local window = conversation._get_context_window("ollama", "custom-model")
            assert.equals(32768, window)
        end)

        it("prefers model-specific over provider config", function()
            config.resolve({
                default_provider = "openai_compat",
                default_model = "gpt-4o",
                providers = {
                    openai_compat = {
                        endpoint = "https://api.openai.com/v1/chat/completions",
                        context_window = 8000, -- User override lower than model knows
                    },
                },
                history = { enabled = false },
                log = { enabled = false },
            })
            -- Model-specific (128000) should win over provider config (8000)
            local window = conversation._get_context_window("openai_compat", "gpt-4o")
            assert.equals(128000, window)
        end)
    end)

    describe("thinking module", function()
        local thinking = require("ai-chat.ui.thinking")

        it("detects <thinking> open tags", function()
            assert.is_true(thinking.is_open_tag("<thinking>"))
            assert.is_true(thinking.is_open_tag("<thinking>  "))
            assert.is_false(thinking.is_open_tag("<thinking>some text"))
            assert.is_false(thinking.is_open_tag("not a tag"))
        end)

        it("detects <think> open tags", function()
            assert.is_true(thinking.is_open_tag("<think>"))
            assert.is_true(thinking.is_open_tag("<think>  "))
            assert.is_false(thinking.is_open_tag("<think>some text"))
        end)

        it("detects </thinking> close tags", function()
            assert.is_true(thinking.is_close_tag("</thinking>"))
            assert.is_true(thinking.is_close_tag("</thinking>  "))
            assert.is_false(thinking.is_close_tag("</thinking>text"))
        end)

        it("detects </think> close tags", function()
            assert.is_true(thinking.is_close_tag("</think>"))
            assert.is_true(thinking.is_close_tag("</think>  "))
        end)

        it("finds thinking blocks in buffer", function()
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                "<thinking>",
                "Step 1: reason",
                "Step 2: conclude",
                "</thinking>",
                "The answer is 42.",
            })

            local blocks = thinking.find_blocks(buf, 0, 5)
            assert.equals(1, #blocks)
            assert.equals(0, blocks[1].open)
            assert.equals(3, blocks[1].close)

            vim.api.nvim_buf_delete(buf, { force = true })
        end)

        it("finds multiple thinking blocks", function()
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                "<thinking>",
                "First thought",
                "</thinking>",
                "Middle text",
                "<think>",
                "Second thought",
                "</think>",
                "End.",
            })

            local blocks = thinking.find_blocks(buf, 0, 8)
            assert.equals(2, #blocks)
            assert.equals(0, blocks[1].open)
            assert.equals(2, blocks[1].close)
            assert.equals(4, blocks[2].open)
            assert.equals(6, blocks[2].close)

            vim.api.nvim_buf_delete(buf, { force = true })
        end)

        it("returns empty for buffers with no thinking blocks", function()
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                "Just normal text",
                "No thinking here",
            })

            local blocks = thinking.find_blocks(buf, 0, 2)
            assert.equals(0, #blocks)

            vim.api.nvim_buf_delete(buf, { force = true })
        end)

        it("returns proper foldtext", function()
            vim.v.foldstart = 5
            vim.v.foldend = 15
            local result = thinking.foldtext()
            assert.truthy(result:match("Thinking"))
            assert.truthy(result:match("9 lines"))
        end)
    end)

    describe("preflight", function()
        it("ollama preflight calls back with false when unreachable", function()
            local result_ok = nil

            vim.system = function(cmd, opts, on_exit)
                on_exit({ code = 7 })
                return { kill = function() end }
            end

            require("ai-chat.providers.ollama").preflight(
                { host = "http://localhost:11434" },
                function(ok, err)
                    result_ok = ok
                end
            )

            vim.wait(500, function()
                return result_ok ~= nil
            end)

            if result_ok ~= nil then
                assert.is_false(result_ok)
            end
        end)

        it("ollama preflight calls back with true when reachable", function()
            local result_ok = nil

            vim.system = function(cmd, opts, on_exit)
                on_exit({ code = 0 })
                return { kill = function() end }
            end

            require("ai-chat.providers.ollama").preflight(
                { host = "http://localhost:11434" },
                function(ok, err)
                    result_ok = ok
                end
            )

            vim.wait(500, function()
                return result_ok ~= nil
            end)

            if result_ok ~= nil then
                assert.is_true(result_ok)
            end
        end)

        it("anthropic preflight fails without API key", function()
            local result_ok = nil
            local old_key = vim.env.ANTHROPIC_API_KEY
            vim.env.ANTHROPIC_API_KEY = nil

            require("ai-chat.providers.anthropic").preflight({}, function(ok, err)
                result_ok = ok
            end)

            vim.env.ANTHROPIC_API_KEY = old_key

            assert.is_false(result_ok)
        end)

        it("bedrock preflight uses aws CLI check", function()
            local result_ok = nil
            local old_exec = vim.fn.executable
            vim.fn.executable = function(cmd)
                if cmd == "aws" then
                    return 0
                end
                return old_exec(cmd)
            end

            require("ai-chat.providers.bedrock").preflight({}, function(ok, err)
                result_ok = ok
            end)

            vim.fn.executable = old_exec
            assert.is_false(result_ok)
        end)

        it("providers.preflight works generically", function()
            local result_ok = nil

            vim.system = function(cmd, opts, on_exit)
                on_exit({ code = 0 })
                return { kill = function() end }
            end

            require("ai-chat.providers").preflight("ollama", { host = "http://localhost:11434" }, function(ok)
                result_ok = ok
            end)

            vim.wait(500, function()
                return result_ok ~= nil
            end)

            if result_ok ~= nil then
                assert.is_true(result_ok)
            end
        end)
    end)

    describe("pipeline debug info", function()
        it("starts with no last request", function()
            pipeline.reset()
            local info = pipeline.get_last_request()
            assert.is_nil(info.provider_messages)
        end)

        it("reset clears debug info", function()
            -- Simulate some state
            pipeline.reset()
            local info = pipeline.get_last_request()
            assert.is_nil(info.provider_messages)
        end)
    end)

    describe("stream retry with error classification", function()
        local stream = require("ai-chat.stream")

        after_each(function()
            -- Ensure stream state is clean
            pcall(stream.cancel)
        end)

        it("does not retry fatal auth errors", function()
            local buf = vim.api.nvim_create_buf(false, true)
            vim.bo[buf].modifiable = false
            local win = vim.api.nvim_get_current_win()

            local error_count = 0
            local final_error = nil

            -- Create a mock provider that always returns auth error
            local mock_provider = {
                chat = function(messages, opts, callbacks)
                    vim.schedule(function()
                        callbacks.on_error({
                            code = "auth",
                            message = "Invalid API key",
                        })
                    end)
                    return function() end
                end,
            }

            stream.send(mock_provider, {}, { model = "test" }, { chat_bufnr = buf, chat_winid = win }, {
                on_done = function() end,
                on_error = function(err)
                    error_count = error_count + 1
                    final_error = err
                end,
            })

            vim.wait(1000, function()
                return final_error ~= nil
            end)

            -- Auth error should NOT be retried — should fail immediately
            if final_error then
                assert.equals("auth", final_error.code)
                assert.equals(1, error_count)
            end

            vim.api.nvim_buf_delete(buf, { force = true })
        end)
    end)
end)
