--- Tests for ai-chat.config — Configuration resolution and validation
local config = require("ai-chat.config")

describe("config.resolve", function()
    it("returns defaults when given empty table", function()
        local resolved = config.resolve({})
        assert.equals("ollama", resolved.default_provider)
        assert.equals("llama3.2", resolved.default_model)
    end)

    it("overrides specific fields", function()
        local resolved = config.resolve({
            default_provider = "anthropic",
            default_model = "claude-sonnet-4-20250514",
        })
        assert.equals("anthropic", resolved.default_provider)
        assert.equals("claude-sonnet-4-20250514", resolved.default_model)
    end)

    it("deep merges nested tables", function()
        local resolved = config.resolve({
            ui = { width = 0.35 },
        })
        assert.equals(0.35, resolved.ui.width)
        -- Other ui fields should still exist
        assert.equals(60, resolved.ui.min_width)
        assert.equals("right", resolved.ui.position)
    end)

    it("deep merges provider config", function()
        local resolved = config.resolve({
            providers = {
                anthropic = {
                    api_key = "test-key",
                },
            },
        })
        assert.equals("test-key", resolved.providers.anthropic.api_key)
        -- Default model should still be set
        assert.equals("claude-sonnet-4-20250514", resolved.providers.anthropic.model)
    end)
end)

describe("config.validate", function()
    it("accepts valid defaults", function()
        local resolved = config.resolve({})
        local ok, err = config.validate(resolved)
        assert.is_true(ok, "defaults should be valid: " .. tostring(err))
    end)

    it("rejects invalid provider", function()
        local resolved = config.resolve({ default_provider = "nonexistent" })
        local ok, err = config.validate(resolved)
        assert.is_false(ok)
        assert.truthy(err:match("Unknown provider"))
    end)

    it("rejects invalid ui.width", function()
        local resolved = config.resolve({ ui = { width = 1.5 } })
        local ok, err = config.validate(resolved)
        assert.is_false(ok)
        assert.truthy(err:match("width"))
    end)

    it("rejects invalid ui.position", function()
        local resolved = config.resolve({ ui = { position = "top" } })
        local ok, err = config.validate(resolved)
        assert.is_false(ok)
        assert.truthy(err:match("position"))
    end)

    it("rejects out-of-range temperature", function()
        local resolved = config.resolve({ chat = { temperature = 5.0 } })
        local ok, err = config.validate(resolved)
        assert.is_false(ok)
        assert.truthy(err:match("temperature"))
    end)

    it("accepts edge-case valid temperature", function()
        local resolved = config.resolve({ chat = { temperature = 0 } })
        local ok = config.validate(resolved)
        assert.is_true(ok)

        resolved = config.resolve({ chat = { temperature = 2.0 } })
        ok = config.validate(resolved)
        assert.is_true(ok)
    end)
end)

describe("config.history_path", function()
    it("returns custom path when configured", function()
        local path = config.history_path({
            history = { storage_path = "/tmp/test-history" },
        })
        assert.equals("/tmp/test-history", path)
    end)

    it("returns default path when not configured", function()
        local path = config.history_path({
            history = { storage_path = nil },
        })
        assert.truthy(path:match("ai%-chat/history$"))
    end)
end)
