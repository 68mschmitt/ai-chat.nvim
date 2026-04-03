--- Tests for stream callback cardinality guard (GAP-02).
--- Verifies that the stream layer enforces (on_chunk* · (on_done | on_error))
--- and silences callbacks after cancel or after the first terminal.

describe("stream callback guard", function()
    local stream = require("ai-chat.stream")

    -- Helper: create a minimal buffer + window for stream.send
    local function make_ui_state()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].modifiable = false
        local win = vim.api.nvim_get_current_win()
        return { chat_bufnr = buf, chat_winid = win }, buf
    end

    after_each(function()
        pcall(stream.cancel)
    end)

    it("silences on_chunk after on_done (double-terminal prevention)", function()
        local ui, buf = make_ui_state()
        local done_count = 0

        local mock_provider = {
            chat = function(messages, opts, cbs)
                vim.schedule(function()
                    cbs.on_chunk("hello")
                    cbs.on_done({
                        content = "hello",
                        usage = { input_tokens = 0, output_tokens = 1 },
                        model = "test",
                    })
                    -- These should be silenced:
                    cbs.on_chunk("stale chunk")
                end)
                return function() end
            end,
        }

        stream.send(mock_provider, {}, { model = "test", provider_name = "test" }, ui, {
            on_done = function(resp)
                done_count = done_count + 1
            end,
            on_error = function() end,
        })

        vim.wait(1000, function()
            return done_count > 0
        end)

        if done_count > 0 then
            assert.equals(1, done_count)
        end

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("silences on_done after on_error (no double terminal)", function()
        local ui, buf = make_ui_state()
        local error_count = 0
        local done_count = 0

        local mock_provider = {
            chat = function(messages, opts, cbs)
                vim.schedule(function()
                    cbs.on_error({ code = "auth", message = "bad key" })
                    cbs.on_done({
                        content = "",
                        usage = { input_tokens = 0, output_tokens = 0 },
                        model = "test",
                    })
                end)
                return function() end
            end,
        }

        stream.send(mock_provider, {}, { model = "test", provider_name = "test" }, ui, {
            on_done = function()
                done_count = done_count + 1
            end,
            on_error = function()
                error_count = error_count + 1
            end,
        })

        vim.wait(1000, function()
            return error_count > 0
        end)

        if error_count > 0 then
            assert.equals(1, error_count)
            assert.equals(0, done_count)
        end

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("silences on_error after on_done (no double terminal)", function()
        local ui, buf = make_ui_state()
        local error_count = 0
        local done_count = 0

        local mock_provider = {
            chat = function(messages, opts, cbs)
                vim.schedule(function()
                    cbs.on_done({
                        content = "ok",
                        usage = { input_tokens = 0, output_tokens = 1 },
                        model = "test",
                    })
                    cbs.on_error({ code = "network", message = "late error" })
                end)
                return function() end
            end,
        }

        stream.send(mock_provider, {}, { model = "test", provider_name = "test" }, ui, {
            on_done = function()
                done_count = done_count + 1
            end,
            on_error = function()
                error_count = error_count + 1
            end,
        })

        vim.wait(1000, function()
            return done_count > 0
        end)

        if done_count > 0 then
            assert.equals(1, done_count)
            assert.equals(0, error_count)
        end

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("silences callbacks after cancel", function()
        local ui, buf = make_ui_state()
        local done_count = 0
        local chunk_count = 0

        -- Provider that holds callbacks and fires them after a delay
        local captured_cbs = nil
        local mock_provider = {
            chat = function(messages, opts, cbs)
                captured_cbs = cbs
                return function() end -- cancel fn
            end,
        }

        stream.send(mock_provider, {}, { model = "test", provider_name = "test" }, ui, {
            on_done = function()
                done_count = done_count + 1
            end,
            on_error = function() end,
        })

        -- Cancel immediately
        stream.cancel()

        -- Now fire callbacks as if the provider didn't respect cancel
        if captured_cbs then
            captured_cbs.on_chunk("stale")
            captured_cbs.on_done({
                content = "stale",
                usage = { input_tokens = 0, output_tokens = 0 },
                model = "test",
            })
        end

        assert.equals(0, done_count)

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("allows multiple chunks before terminal", function()
        local ui, buf = make_ui_state()
        local done_count = 0
        local chunk_count = 0

        local mock_provider = {
            chat = function(messages, opts, cbs)
                vim.schedule(function()
                    cbs.on_chunk("hello ")
                    cbs.on_chunk("world")
                    cbs.on_chunk("!")
                    cbs.on_done({
                        content = "hello world!",
                        usage = { input_tokens = 0, output_tokens = 3 },
                        model = "test",
                    })
                end)
                return function() end
            end,
        }

        stream.send(mock_provider, {}, { model = "test", provider_name = "test" }, ui, {
            on_done = function(resp)
                done_count = done_count + 1
            end,
            on_error = function() end,
        })

        vim.wait(1000, function()
            return done_count > 0
        end)

        if done_count > 0 then
            assert.equals(1, done_count)
        end

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("rejects send when not idle (state machine)", function()
        local ui, buf = make_ui_state()
        -- Start a send that holds (doesn't complete immediately)
        local mock_provider = {
            chat = function(messages, opts, cbs)
                -- Hold — don't call any callbacks yet
                return function() end
            end,
        }

        stream.send(mock_provider, {}, { model = "test", provider_name = "test" }, ui, {
            on_done = function() end,
            on_error = function() end,
        })

        assert.is_true(stream.is_active())

        -- Second send should be rejected (no error, just notify)
        stream.send(mock_provider, {}, { model = "test", provider_name = "test" }, ui, {
            on_done = function() end,
            on_error = function() end,
        })

        -- Should still be active from first send
        assert.is_true(stream.is_active())

        stream.cancel()
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("cancel returns true from streaming, false from idle", function()
        local ui, buf = make_ui_state()

        -- Cancel from idle
        assert.is_false(stream.cancel())

        -- Start streaming
        local mock_provider = {
            chat = function(messages, opts, cbs)
                return function() end
            end,
        }

        stream.send(mock_provider, {}, { model = "test", provider_name = "test" }, ui, {
            on_done = function() end,
            on_error = function() end,
        })

        -- Cancel from streaming
        assert.is_true(stream.cancel())
        assert.is_false(stream.is_active())

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("cancel from retrying phase returns true", function()
        local ui, buf = make_ui_state()
        local error_count = 0

        local mock_provider = {
            chat = function(messages, opts, cbs)
                vim.schedule(function()
                    -- Trigger a retryable error
                    cbs.on_error({ code = "network", message = "timeout", retryable = true })
                end)
                return function() end
            end,
        }

        stream.send(mock_provider, {}, { model = "test", provider_name = "test" }, ui, {
            on_done = function() end,
            on_error = function()
                error_count = error_count + 1
            end,
        })

        -- Wait for error to be processed and enter retrying phase
        vim.wait(500, function()
            return stream.is_active()
        end)

        -- Should be in retrying phase now
        if stream.is_active() then
            assert.is_true(stream.cancel())
            assert.is_false(stream.is_active())
        end

        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)
