--- Tests for ai-chat.util.tokens — Approximate token counting
local tokens = require("ai-chat.util.tokens")

describe("tokens.estimate", function()
    it("returns 0 for empty string", function()
        assert.equals(0, tokens.estimate(""))
    end)

    it("returns 0 for nil", function()
        assert.equals(0, tokens.estimate(nil))
    end)

    it("estimates tokens for simple text", function()
        local count = tokens.estimate("hello world foo bar")
        assert.is_true(count > 0, "should estimate > 0 tokens")
        assert.is_true(count < 20, "should be reasonable for 4 words, got: " .. count)
    end)

    it("estimates more tokens for longer text", function()
        local short = tokens.estimate("hello world")
        local long = tokens.estimate("hello world foo bar baz qux corge grault garply")
        assert.is_true(long > short, "longer text should have more tokens")
    end)

    it("handles code with special characters", function()
        local count = tokens.estimate("local x = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)")
        assert.is_true(count > 0, "code should produce tokens")
    end)

    it("handles multi-line text", function()
        local count = tokens.estimate("line one\nline two\nline three")
        assert.is_true(count > 0, "multi-line text should produce tokens")
    end)

    it("handles whitespace-only input", function()
        local count = tokens.estimate("   \t\n   ")
        assert.equals(0, count, "whitespace-only should be 0 tokens")
    end)
end)
