describe("openai_subscription provider", function()
    local provider = require("ai-chat.providers.openai_subscription")
    local store = require("ai-chat.auth.store")
    local original_system
    local tmpdir

    before_each(function()
        original_system = vim.system
        tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, "p")
        store._set_path(tmpdir .. "/auth.json")
        store.set("openai", {
            type = "oauth",
            refresh = "refresh-token",
            access = "access-token",
            expires = os.time() * 1000 + 3600000,
            accountId = "account-123",
        })
    end)

    after_each(function()
        vim.system = original_system
        store._set_path(nil)
        vim.fn.delete(tmpdir, "rf")
    end)

    it("exposes the provider contract", function()
        assert.is_function(provider.validate)
        assert.is_function(provider.preflight)
        assert.is_function(provider.list_models)
        assert.is_function(provider.chat)
    end)

    it("reports auth failure when no oauth token exists", function()
        store.delete("openai")
        local ok, err = provider.validate({})
        assert.is_false(ok)
        assert.truthy(err:match("not authenticated"))
    end)

    it("sends Codex backend request with OAuth headers and instructions", function()
        local captured_cmd
        local captured_body
        vim.system = function(cmd, opts, on_exit)
            captured_cmd = cmd
            for i, arg in ipairs(cmd) do
                if arg == "-d" then
                    local body_file = cmd[i + 1]:sub(2)
                    captured_body = vim.json.decode(table.concat(vim.fn.readfile(body_file), "\n"))
                end
            end
            vim.schedule(function()
                opts.stdout(
                    nil,
                    'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"hello"}\n\n'
                )
                opts.stdout(
                    nil,
                    'event: response.completed\ndata: {"type":"response.completed","usage":{"input_tokens":1,"output_tokens":2}}\n\n'
                )
                on_exit({ code = 0 })
            end)
            return { kill = function() end }
        end

        local done
        local chunks = {}
        provider.chat({
            { role = "system", content = "sys" },
            { role = "user", content = "hi" },
        }, {
            model = "gpt-5.5",
            provider_config = { codex_endpoint = "https://chatgpt.com/backend-api/codex/responses" },
        }, {
            on_chunk = function(text)
                chunks[#chunks + 1] = text
            end,
            on_done = function(response)
                done = response
            end,
            on_error = function(err)
                error(err.message)
            end,
        })

        vim.wait(1000, function()
            return done ~= nil
        end)

        assert.equals("hello", table.concat(chunks, ""))
        assert.equals("hello", done.content)
        assert.equals(1, done.usage.input_tokens)
        assert.equals(2, done.usage.output_tokens)
        assert.equals("sys", captured_body.instructions)
        assert.is_nil(captured_body.max_tokens)
        assert.is_nil(captured_body.temperature)
        assert.equals(false, captured_body.store)
        for i, arg in ipairs(captured_cmd) do
            if arg == "-H" then
                assert.is_not.equals("-H", captured_cmd[i + 1], "-H must be followed by a header value")
            end
        end
        assert.truthy(vim.tbl_contains(captured_cmd, "Authorization: Bearer access-token"))
        assert.truthy(vim.tbl_contains(captured_cmd, "ChatGPT-Account-Id: account-123"))
    end)

    it("omits account header when account id is absent", function()
        store.set("openai", {
            type = "oauth",
            refresh = "refresh-token",
            access = "access-token",
            expires = os.time() * 1000 + 3600000,
        })
        local captured_cmd
        local call_count = 0
        vim.system = function(cmd, opts, on_exit)
            call_count = call_count + 1
            if call_count == 1 then
                vim.schedule(function()
                    on_exit({ code = 0, stdout = "{}" })
                end)
                return { kill = function() end }
            end
            captured_cmd = cmd
            vim.schedule(function()
                opts.stdout(
                    nil,
                    'event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"ok"}\n\n'
                )
                on_exit({ code = 0 })
            end)
            return { kill = function() end }
        end

        local done
        provider.chat({ { role = "user", content = "hi" } }, { provider_config = {} }, {
            on_chunk = function() end,
            on_done = function(response)
                done = response
            end,
            on_error = function(err)
                error(err.message)
            end,
        })
        vim.wait(1000, function()
            return done ~= nil
        end)
        assert.truthy(vim.tbl_contains(captured_cmd, "Authorization: Bearer access-token"))
        assert.is_false(vim.tbl_contains(captured_cmd, "ChatGPT-Account-Id: account-123"))
    end)

    it("uses completed response text when no delta events are present", function()
        vim.system = function(_cmd, opts, on_exit)
            vim.schedule(function()
                opts.stdout(
                    nil,
                    'event: response.completed\ndata: {"type":"response.completed","response":{"output":[{"content":[{"type":"output_text","text":"final hello"}]}]}}\n\n'
                )
                on_exit({ code = 0 })
            end)
            return { kill = function() end }
        end

        local done
        provider.chat({ { role = "user", content = "hi" } }, { provider_config = {} }, {
            on_chunk = function() end,
            on_done = function(response)
                done = response
            end,
            on_error = function(err)
                error(err.message)
            end,
        })
        vim.wait(1000, function()
            return done ~= nil
        end)
        assert.equals("final hello", done.content)
    end)

    it("parses line-delimited data events without SSE blank lines", function()
        vim.system = function(_cmd, opts, on_exit)
            vim.schedule(function()
                opts.stdout(nil, 'data: {"type":"response.output_text.delta","delta":"line hello"}\n')
                on_exit({ code = 0 })
            end)
            return { kill = function() end }
        end

        local done
        provider.chat({ { role = "user", content = "hi" } }, { provider_config = {} }, {
            on_chunk = function() end,
            on_done = function(response)
                done = response
            end,
            on_error = function(err)
                error(err.message)
            end,
        })
        vim.wait(1000, function()
            return done ~= nil
        end)
        assert.equals("line hello", done.content)
    end)

    it("maps plain unauthorized JSON to auth error", function()
        vim.system = function(_cmd, opts, on_exit)
            vim.schedule(function()
                opts.stdout(nil, '{"detail":"Unauthorized"}')
                on_exit({ code = 0 })
            end)
            return { kill = function() end }
        end

        local got_err
        provider.chat({ { role = "user", content = "hi" } }, { provider_config = {} }, {
            on_chunk = function() end,
            on_done = function() end,
            on_error = function(err)
                got_err = err
            end,
        })

        vim.wait(1000, function()
            return got_err ~= nil
        end)
        assert.equals("auth", got_err.code)
    end)

    it("ignores JSON null usage", function()
        vim.system = function(_cmd, opts, on_exit)
            vim.schedule(function()
                opts.stdout(
                    nil,
                    'event: response.completed\ndata: {"type":"response.completed","response":{"usage":null,"output":[{"content":[{"type":"output_text","text":"ok"}]}]}}\n\n'
                )
                on_exit({ code = 0 })
            end)
            return { kill = function() end }
        end

        local done
        provider.chat({ { role = "user", content = "hi" } }, { provider_config = {} }, {
            on_chunk = function() end,
            on_done = function(response)
                done = response
            end,
            on_error = function(err)
                error(err.message)
            end,
        })
        vim.wait(1000, function()
            return done ~= nil
        end)
        assert.equals("ok", done.content)
        assert.equals(0, done.usage.input_tokens)
        assert.equals(0, done.usage.output_tokens)
    end)

    it("maps unsupported model detail to model_not_found", function()
        vim.system = function(_cmd, opts, on_exit)
            vim.schedule(function()
                opts.stdout(nil, '{"detail":"The model is not supported when using Codex with a ChatGPT account."}')
                on_exit({ code = 0 })
            end)
            return { kill = function() end }
        end

        local got_err
        provider.chat({ { role = "user", content = "hi" } }, { provider_config = {} }, {
            on_chunk = function() end,
            on_done = function() end,
            on_error = function(err)
                got_err = err
            end,
        })

        vim.wait(1000, function()
            return got_err ~= nil
        end)
        assert.equals("model_not_found", got_err.code)
    end)

    it("maps usage_not_included to auth error", function()
        vim.system = function(_cmd, opts, _on_exit)
            vim.schedule(function()
                opts.stdout(
                    nil,
                    'event: response.error\ndata: {"type":"response.error","error":{"code":"usage_not_included","message":"nope"}}\n\n'
                )
            end)
            return { kill = function() end }
        end

        local got_err
        provider.chat({ { role = "user", content = "hi" } }, { provider_config = {} }, {
            on_chunk = function() end,
            on_done = function() end,
            on_error = function(err)
                got_err = err
            end,
        })

        vim.wait(1000, function()
            return got_err ~= nil
        end)
        assert.equals("auth", got_err.code)
    end)
end)
