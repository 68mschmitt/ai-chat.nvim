--- Tests for ai-chat.state — Persisted user state (last model/provider)

-- Use a temp directory for test isolation
local test_dir = vim.fn.tempname() .. "/ai-chat-test-state"

--- Reload the state module fresh (replaces _reset pattern)
local function reload_state()
    package.loaded["ai-chat.state"] = nil
    return require("ai-chat.state")
end

describe("state", function()
    local state

    before_each(function()
        vim.fn.mkdir(test_dir, "p")
        state = reload_state()
        state.init(test_dir)
    end)

    after_each(function()
        state = reload_state()
        vim.fn.delete(test_dir, "rf")
    end)

    describe("initial state", function()
        it("returns nil for provider when nothing persisted", function()
            state.load()
            assert.is_nil(state.get_last_provider())
        end)

        it("returns nil for model when nothing persisted", function()
            state.load()
            assert.is_nil(state.get_last_model())
        end)

        it("load returns empty table when no file exists", function()
            local loaded = state.load()
            assert.is_table(loaded)
        end)
    end)

    describe("set and get", function()
        it("persists provider and model to memory", function()
            state.set_last_model("bedrock", "anthropic.claude-sonnet-4-20250514-v1:0")
            assert.equals("bedrock", state.get_last_provider())
            assert.equals("anthropic.claude-sonnet-4-20250514-v1:0", state.get_last_model())
        end)

        it("overwrites previous values", function()
            state.set_last_model("ollama", "llama3.2")
            state.set_last_model("anthropic", "claude-sonnet-4-20250514")
            assert.equals("anthropic", state.get_last_provider())
            assert.equals("claude-sonnet-4-20250514", state.get_last_model())
        end)
    end)

    describe("persistence round-trip", function()
        it("survives save and reload", function()
            state.set_last_model("bedrock", "anthropic.claude-opus-4-20250514-v1:0")

            -- Simulate restart: reload module and reinit from disk
            state = reload_state()
            state.init(test_dir)
            state.load()

            assert.equals("bedrock", state.get_last_provider())
            assert.equals("anthropic.claude-opus-4-20250514-v1:0", state.get_last_model())
        end)

        it("creates the state file on disk", function()
            state.set_last_model("ollama", "mistral")
            local filepath = test_dir .. "/state.json"
            assert.equals(1, vim.fn.filereadable(filepath))
        end)
    end)

    describe("corrupt file handling", function()
        it("returns empty state for corrupt JSON", function()
            local filepath = test_dir .. "/state.json"
            vim.fn.writefile({ "this is not valid json {{{" }, filepath)

            local loaded = state.load()
            assert.is_table(loaded)
            assert.is_nil(state.get_last_provider())
            assert.is_nil(state.get_last_model())
        end)

        it("returns empty state for empty file", function()
            local filepath = test_dir .. "/state.json"
            vim.fn.writefile({}, filepath)

            local loaded = state.load()
            assert.is_table(loaded)
            assert.is_nil(state.get_last_provider())
        end)
    end)

    describe("reset", function()
        it("reload clears in-memory state", function()
            state.set_last_model("anthropic", "claude-sonnet-4-20250514")
            state = reload_state()
            assert.is_nil(state.get_last_provider())
            assert.is_nil(state.get_last_model())
        end)
    end)
end)
