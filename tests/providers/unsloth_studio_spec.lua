describe("unsloth_studio provider", function()
    local original_system = vim.system
    local original_unsloth_key = vim.env.UNSLOTH_API_KEY

    before_each(function()
        package.loaded["ai-chat.providers.unsloth_studio"] = nil
        vim.env.UNSLOTH_API_KEY = nil
    end)

    after_each(function()
        vim.system = original_system
        vim.env.UNSLOTH_API_KEY = original_unsloth_key
        package.loaded["ai-chat.providers.unsloth_studio"] = nil
    end)

    local function has_arg(cmd, value)
        for _, arg in ipairs(cmd) do
            if arg == value then
                return true
            end
        end
        return false
    end

    local function last_arg(cmd)
        return cmd[#cmd]
    end

    local function read_body_from_curl(cmd)
        for i, arg in ipairs(cmd) do
            if arg == "-d" and cmd[i + 1] and cmd[i + 1]:sub(1, 1) == "@" then
                local lines = vim.fn.readfile(cmd[i + 1]:sub(2))
                return vim.json.decode(lines[1])
            end
        end
        return nil
    end

    it("does not require an API key for local Studio", function()
        local provider = require("ai-chat.providers.unsloth_studio")
        local ok = provider.validate({ endpoint = "http://localhost:8000/v1" })
        assert.is_true(ok)
    end)

    it("lists models from the OpenAI-compatible /models endpoint without auth", function()
        local captured_cmd = nil
        local models = nil

        vim.system = function(cmd, _opts, on_exit)
            captured_cmd = cmd
            vim.schedule(function()
                on_exit({ code = 0, stdout = '{"data":[{"id":"llama"},{"id":"mistral"}]}' })
            end)
            return { kill = function() end }
        end

        local provider = require("ai-chat.providers.unsloth_studio")
        provider.list_models({ endpoint = "http://localhost:8000/v1" }, function(result)
            models = result
        end)

        vim.wait(1000, function()
            return models ~= nil
        end)

        assert.equals("http://localhost:8000/v1/models", last_arg(captured_cmd))
        assert.is_false(has_arg(captured_cmd, "Authorization: Bearer "))
        assert.equals("llama", models[1])
        assert.equals("mistral", models[2])
    end)

    it("falls back to POST model discovery and exposes Studio API URLs as options", function()
        local calls = {}
        local models = nil

        vim.system = function(cmd, _opts, on_exit)
            table.insert(calls, cmd)
            vim.schedule(function()
                if #calls == 1 then
                    on_exit({ code = 0, stdout = "{}" })
                else
                    on_exit({
                        code = 0,
                        stdout = vim.json.encode({
                            models = {
                                { name = "llama", api_url = "http://127.0.0.1:8000/api/llama" },
                                { name = "mistral", url = "http://127.0.0.1:8000/api/mistral" },
                            },
                        }),
                    })
                end
            end)
            return { kill = function() end }
        end

        local provider = require("ai-chat.providers.unsloth_studio")
        provider.list_models({ endpoint = "http://localhost:8000/v1" }, function(result)
            models = result
        end)

        vim.wait(1000, function()
            return models ~= nil
        end)

        assert.equals(2, #calls)
        assert.is_false(has_arg(calls[1], "POST"))
        assert.is_true(has_arg(calls[2], "POST"))
        assert.equals("http://127.0.0.1:8000/api/llama", models[1])
        assert.equals("http://127.0.0.1:8000/api/mistral", models[2])
    end)

    it("uses a selected Studio API URL as the chat endpoint", function()
        local captured_cmd = nil
        local captured_body = nil
        local done = nil

        vim.system = function(cmd, opts, on_exit)
            captured_cmd = cmd
            captured_body = read_body_from_curl(cmd)
            if opts.stdout then
                vim.schedule(function()
                    opts.stdout(nil, 'data: {"choices":[{"delta":{"content":"Hi"}}]}\n')
                    opts.stdout(nil, 'data: {"usage":{"prompt_tokens":3,"completion_tokens":2}}\n')
                    opts.stdout(nil, "data: [DONE]\n")
                end)
            end
            vim.schedule(function()
                on_exit({ code = 0 })
            end)
            return { kill = function() end }
        end

        local provider = require("ai-chat.providers.unsloth_studio")
        provider.chat({ { role = "user", content = "hello" } }, {
            model = "http://127.0.0.1:8000/api/llama",
            provider_config = { model_name = "llama" },
        }, {
            on_chunk = function() end,
            on_done = function(response)
                done = response
            end,
            on_error = function(err)
                error("unexpected error: " .. vim.inspect(err))
            end,
        })

        vim.wait(1000, function()
            return done ~= nil
        end)

        assert.equals("http://127.0.0.1:8000/api/llama", last_arg(captured_cmd))
        assert.equals("llama", captured_body.model)
        assert.equals("Hi", done.content)
        assert.equals(3, done.usage.input_tokens)
        assert.equals(2, done.usage.output_tokens)
    end)

    it("does not duplicate /chat/completions when endpoint is already complete", function()
        local captured_cmd = nil
        local done = nil

        vim.system = function(cmd, opts, on_exit)
            captured_cmd = cmd
            if opts.stdout then
                vim.schedule(function()
                    opts.stdout(nil, "data: [DONE]\n")
                end)
            end
            vim.schedule(function()
                on_exit({ code = 0 })
            end)
            return { kill = function() end }
        end

        local provider = require("ai-chat.providers.unsloth_studio")
        provider.chat({ { role = "user", content = "hello" } }, {
            model = "llama",
            provider_config = { endpoint = "http://localhost:8000/v1/chat/completions" },
        }, {
            on_chunk = function() end,
            on_done = function(response)
                done = response
            end,
            on_error = function(err)
                error("unexpected error: " .. vim.inspect(err))
            end,
        })

        vim.wait(1000, function()
            return done ~= nil
        end)

        assert.equals("http://localhost:8000/v1/chat/completions", last_arg(captured_cmd))
    end)
end)
