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

describe("conversation.append validation", function()
    before_each(function()
        conversation.new("ollama", "llama3.2")
    end)

    it("accepts valid user message", function()
        conversation.append({ role = "user", content = "hello" })
        assert.equals(1, conversation.message_count())
        local conv = conversation.get()
        assert.equals("user", conv.messages[1].role)
        assert.equals("hello", conv.messages[1].content)
    end)

    it("accepts valid assistant message", function()
        conversation.append({ role = "user", content = "hello" })
        conversation.append({ role = "assistant", content = "hi" })
        assert.equals(2, conversation.message_count())
    end)

    it("accepts assistant message with empty content (cancelled stream)", function()
        conversation.append({ role = "user", content = "hello" })
        conversation.append({ role = "assistant", content = "" })
        assert.equals(2, conversation.message_count())
    end)

    it("accepts messages with extra fields", function()
        conversation.append({ role = "user", content = "hello", timestamp = 1000 })
        conversation.append({
            role = "assistant",
            content = "hi",
            usage = { input_tokens = 10, output_tokens = 5 },
            model = "llama3.2",
            thinking = "let me think...",
            timestamp = 1001,
        })
        assert.equals(2, conversation.message_count())
    end)

    it("rejects non-table message", function()
        local ok, err = pcall(conversation.append, "not a table")
        assert.is_false(ok)
        assert.truthy(err, "should have error message")
        assert.equals(0, conversation.message_count())
    end)

    it("rejects message with missing role", function()
        local ok, err = pcall(conversation.append, { content = "no role" })
        assert.is_false(ok)
        assert.truthy(err, "should have error message")
        assert.equals(0, conversation.message_count())
    end)

    it("rejects message with missing content", function()
        local ok, err = pcall(conversation.append, { role = "user" })
        assert.is_false(ok)
        assert.truthy(err, "should have error message")
        assert.equals(0, conversation.message_count())
    end)

    it("rejects message with invalid role", function()
        local ok, err = pcall(conversation.append, { role = "admin", content = "x" })
        assert.is_false(ok)
        assert.truthy(err, "should have error message")
        assert.equals(0, conversation.message_count())
    end)

    it("rejects system role", function()
        local ok, err = pcall(conversation.append, { role = "system", content = "x" })
        assert.is_false(ok)
        assert.truthy(err, "should have error message")
        assert.equals(0, conversation.message_count())
    end)

    it("rejects user message with empty content", function()
        local ok, err = pcall(conversation.append, { role = "user", content = "" })
        assert.is_false(ok)
        assert.truthy(err, "should have error message")
        assert.equals(0, conversation.message_count())
    end)

    it("includes actual type in error for non-table", function()
        local ok, err = pcall(conversation.append, 42)
        assert.is_false(ok)
        assert.truthy(err:find("number"), "error should mention 'number'")
    end)

    it("includes actual role in error for invalid role", function()
        local ok, err = pcall(conversation.append, { role = "admin", content = "x" })
        assert.is_false(ok)
        assert.truthy(err:find("admin"), "error should mention 'admin'")
    end)
end)

describe("conversation.restore validation", function()
    it("keeps valid messages and skips invalid ones", function()
        conversation.restore({
            id = "test-restore-validation",
            messages = {
                { role = "user", content = "hello" },
                { role = "invalid", content = "bad role" },
                { role = "assistant", content = "hi" },
                "not a table",
                { role = "user", content = "another" },
            },
            provider = "ollama",
            model = "llama3.2",
            created_at = 1000,
        })

        assert.equals(3, conversation.message_count())
        local conv = conversation.get()
        assert.equals("user", conv.messages[1].role)
        assert.equals("hello", conv.messages[1].content)
        assert.equals("assistant", conv.messages[2].role)
        assert.equals("hi", conv.messages[2].content)
        assert.equals("user", conv.messages[3].role)
        assert.equals("another", conv.messages[3].content)
    end)

    it("produces empty conversation when all messages are invalid", function()
        conversation.restore({
            id = "test-all-invalid",
            messages = {
                "string",
                42,
                { role = "bad" },
            },
            provider = "ollama",
            model = "llama3.2",
        })

        assert.equals(0, conversation.message_count())
    end)

    it("handles missing messages field gracefully", function()
        conversation.restore({
            id = "test-no-messages",
            provider = "ollama",
            model = "llama3.2",
        })

        assert.equals(0, conversation.message_count())
    end)

    it("preserves valid conversation metadata", function()
        conversation.restore({
            id = "meta-test",
            messages = {
                { role = "user", content = "hello" },
                { content = "missing role" }, -- invalid, skipped
            },
            provider = "anthropic",
            model = "claude-sonnet-4-20250514",
            created_at = 12345,
        })

        local conv = conversation.get()
        assert.equals("meta-test", conv.id)
        assert.equals("anthropic", conv.provider)
        assert.equals("claude-sonnet-4-20250514", conv.model)
        assert.equals(12345, conv.created_at)
        assert.equals(1, #conv.messages)
    end)
end)
