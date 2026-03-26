--- Tests for ai-chat.conversation — Conversation state management
local conversation = require("ai-chat.conversation")

describe("conversation.new", function()
    it("creates a conversation with provider and model", function()
        local conv = conversation.new("ollama", "llama3.2")
        assert.equals("ollama", conv.provider)
        assert.equals("llama3.2", conv.model)
        assert.is_table(conv.messages)
        assert.equals(0, #conv.messages)
        assert.truthy(conv.id, "should have an id")
        assert.truthy(conv.created_at, "should have created_at")
    end)

    it("generates unique IDs", function()
        local conv1 = conversation.new("ollama", "a")
        local conv2 = conversation.new("ollama", "b")
        assert.is_not.equals(conv1.id, conv2.id)
    end)
end)

describe("conversation.append", function()
    it("adds messages to the conversation", function()
        conversation.new("ollama", "llama3.2")
        assert.equals(0, conversation.message_count())

        conversation.append({ role = "user", content = "hello" })
        assert.equals(1, conversation.message_count())

        conversation.append({ role = "assistant", content = "hi" })
        assert.equals(2, conversation.message_count())
    end)
end)

describe("conversation.get", function()
    it("returns a copy (not the original)", function()
        conversation.new("ollama", "llama3.2")
        conversation.append({ role = "user", content = "hello" })

        local copy = conversation.get()
        -- Mutating the copy should not affect the original
        copy.messages = {}
        assert.equals(1, conversation.message_count())
    end)
end)

describe("conversation.set_provider and set_model", function()
    it("updates provider and model", function()
        conversation.new("ollama", "llama3.2")

        conversation.set_provider("anthropic")
        assert.equals("anthropic", conversation.get_provider())

        conversation.set_model("claude-sonnet-4-20250514")
        assert.equals("claude-sonnet-4-20250514", conversation.get_model())
    end)
end)

describe("conversation.restore", function()
    it("restores from a saved conversation", function()
        conversation.restore({
            id = "test-123",
            messages = {
                { role = "user", content = "hello" },
                { role = "assistant", content = "hi" },
            },
            provider = "anthropic",
            model = "claude-sonnet-4-20250514",
            created_at = 1000,
        })

        local conv = conversation.get()
        assert.equals("test-123", conv.id)
        assert.equals(2, #conv.messages)
        assert.equals("anthropic", conv.provider)
    end)
end)

describe("conversation.build_provider_messages", function()
    it("includes system prompt and messages", function()
        conversation.new("ollama", "llama3.2")
        conversation.append({ role = "user", content = "hello" })
        conversation.append({ role = "assistant", content = "hi" })

        local config = require("ai-chat.config").resolve({})
        local messages, truncated = conversation.build_provider_messages(config)

        assert.is_table(messages)
        assert.is_true(#messages >= 3, "should have system + 2 messages")
        assert.equals("system", messages[1].role)
        assert.equals("user", messages[2].role)
        assert.equals("assistant", messages[3].role)
        assert.is_nil(truncated, "should not truncate short conversations")
    end)

    it("inlines context into user messages", function()
        conversation.new("ollama", "llama3.2")
        conversation.append({
            role = "user",
            content = "explain this",
            context = {
                { type = "buffer", source = "test.lua", content = "local x = 1" },
            },
        })

        local config = require("ai-chat.config").resolve({})
        local messages = conversation.build_provider_messages(config)

        -- The user message should have context inlined
        assert.truthy(messages[2].content:match("context"))
        assert.truthy(messages[2].content:match("local x = 1"))
    end)
end)

describe("conversation._truncate_to_budget", function()
    it("does not truncate when under budget", function()
        local messages = {
            { role = "system", content = "system prompt" },
            { role = "user", content = "hello" },
            { role = "assistant", content = "hi" },
        }
        local dropped = conversation._truncate_to_budget(messages, 10000)
        assert.is_nil(dropped)
        assert.equals(3, #messages)
    end)

    it("drops oldest messages first", function()
        local messages = {
            { role = "system", content = "system prompt" },
            { role = "user", content = string.rep("word ", 500) }, -- ~665 tokens
            { role = "assistant", content = string.rep("word ", 500) }, -- ~665 tokens
            { role = "user", content = string.rep("word ", 500) }, -- ~665 tokens
            { role = "assistant", content = "short response" }, -- ~3 tokens
        }
        local dropped = conversation._truncate_to_budget(messages, 700)
        assert.truthy(dropped, "should have truncated")
        assert.is_true(dropped > 0)
        -- System prompt (index 1) should always be preserved
        assert.equals("system", messages[1].role)
    end)

    it("always preserves system prompt and at least one message", function()
        local messages = {
            { role = "system", content = string.rep("word ", 1000) },
            { role = "user", content = "hello" },
        }
        local dropped = conversation._truncate_to_budget(messages, 10)
        -- Even if budget is tiny, should keep at least system + 1 message
        assert.equals(2, #messages)
    end)
end)
