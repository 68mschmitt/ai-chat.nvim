--- Tests for ai-chat.commands — Command router parsing and dispatch
local commands = require("ai-chat.commands")

describe("command router", function()
    local mock_state = {
        config = require("ai-chat.config").defaults,
        conversation = {
            messages = {},
            provider = "ollama",
            model = "llama3.2",
        },
    }

    describe("parsing", function()
        it("parses command name and args", function()
            -- /context has no side effects beyond rendering, safe to test
            assert.has_no.errors(function()
                commands.handle("/context", mock_state)
            end)
        end)

        it("parses command with arguments", function()
            -- /model with an arg should not error (it calls set_model)
            assert.has_no.errors(function()
                commands.handle("/model llama3.2", mock_state)
            end)
        end)

        it("parses command with no arguments", function()
            assert.has_no.errors(function()
                commands.handle("/context", mock_state)
            end)
        end)

        it("parses command with extra whitespace", function()
            assert.has_no.errors(function()
                commands.handle("/context   ", mock_state)
            end)
        end)
    end)

    describe("unknown commands", function()
        it("handles unknown command gracefully", function()
            assert.has_no.errors(function()
                commands.handle("/nonexistent", mock_state)
            end)
        end)

        it("handles unknown command with args gracefully", function()
            assert.has_no.errors(function()
                commands.handle("/nonexistent some args here", mock_state)
            end)
        end)
    end)

    describe("malformed input", function()
        it("handles slash with no command name", function()
            -- "/" alone — the pattern match will fail, should notify
            assert.has_no.errors(function()
                commands.handle("/", mock_state)
            end)
        end)

        it("handles empty string after slash", function()
            assert.has_no.errors(function()
                commands.handle("/ ", mock_state)
            end)
        end)
    end)
end)
