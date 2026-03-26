--- Tests for ai-chat.commands.slash — Slash command routing and definitions
local slash = require("ai-chat.commands.slash")

describe("slash commands", function()
    it("has all expected commands registered", function()
        assert.is_function(slash.commands.clear)
        assert.is_function(slash.commands.new)
        assert.is_function(slash.commands.model)
        assert.is_function(slash.commands.provider)
        assert.is_function(slash.commands.context)
        assert.is_function(slash.commands.save)
        assert.is_function(slash.commands.load)
        assert.is_function(slash.commands.help)
        assert.is_function(slash.commands.thinking)
    end)

    it("lists all commands", function()
        local list = slash.list()
        assert.is_table(list)
        assert.is_true(#list > 0, "should have at least one command")
        -- Check that key commands are in the list
        local found_clear = false
        local found_help = false
        for _, name in ipairs(list) do
            if name == "clear" then
                found_clear = true
            end
            if name == "help" then
                found_help = true
            end
        end
        assert.is_true(found_clear, "should include 'clear'")
        assert.is_true(found_help, "should include 'help'")
    end)
end)

describe("command router", function()
    it("routes valid commands", function()
        local commands = require("ai-chat.commands")
        -- /context doesn't need special state, just test it doesn't error
        -- We need a mock state that has the conversation field
        local mock_state = {
            config = require("ai-chat.config").defaults,
            conversation = {
                messages = {},
                provider = "ollama",
                model = "llama3.2",
            },
        }

        -- /context should not error (it renders a message)
        assert.has_no.errors(function()
            commands.handle("/context", mock_state)
        end)
    end)

    it("handles unknown commands gracefully", function()
        local commands = require("ai-chat.commands")
        local mock_state = {
            config = require("ai-chat.config").defaults,
            conversation = { messages = {} },
        }
        -- Should not error, should notify
        assert.has_no.errors(function()
            commands.handle("/nonexistent", mock_state)
        end)
    end)
end)
