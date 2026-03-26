--- Tests for ai-chat.history.store — JSON file-based conversation storage
local store = require("ai-chat.history.store")

-- Use a temp directory for test isolation
local test_dir = vim.fn.tempname() .. "/ai-chat-test-store"

describe("history store", function()
    before_each(function()
        -- Fresh directory for each test
        vim.fn.mkdir(test_dir, "p")
        store.init(test_dir, 100)
    end)

    after_each(function()
        -- Clean up
        vim.fn.delete(test_dir, "rf")
    end)

    describe("write and read", function()
        it("round-trips a conversation through JSON", function()
            local entry = {
                id = "test-uuid-001",
                name = "Test conversation",
                provider = "ollama",
                model = "llama3.2",
                created_at = 1700000000,
                updated_at = 1700000100,
                message_count = 2,
                messages = {
                    { role = "user", content = "Hello", timestamp = 1700000000 },
                    { role = "assistant", content = "Hi there!", timestamp = 1700000050 },
                },
            }

            store.write(entry)
            local loaded = store.read("test-uuid-001")

            assert.is_not_nil(loaded)
            assert.equals("test-uuid-001", loaded.id)
            assert.equals("Test conversation", loaded.name)
            assert.equals("ollama", loaded.provider)
            assert.equals("llama3.2", loaded.model)
            assert.equals(2, loaded.message_count)
            assert.equals(2, #loaded.messages)
            assert.equals("Hello", loaded.messages[1].content)
            assert.equals("Hi there!", loaded.messages[2].content)
        end)

        it("returns nil for nonexistent ID", function()
            local loaded = store.read("does-not-exist")
            assert.is_nil(loaded)
        end)

        it("overwrites existing conversation on re-write", function()
            local entry = {
                id = "test-uuid-002",
                name = "Original",
                provider = "ollama",
                model = "llama3.2",
                created_at = 1700000000,
                updated_at = 1700000100,
                message_count = 1,
                messages = { { role = "user", content = "First" } },
            }

            store.write(entry)

            entry.name = "Updated"
            entry.message_count = 2
            table.insert(entry.messages, { role = "assistant", content = "Second" })
            store.write(entry)

            local loaded = store.read("test-uuid-002")
            assert.equals("Updated", loaded.name)
            assert.equals(2, #loaded.messages)
        end)
    end)

    describe("list", function()
        it("returns empty list when no conversations exist", function()
            local entries = store.list()
            assert.is_table(entries)
            assert.equals(0, #entries)
        end)

        it("lists conversations sorted by updated_at descending", function()
            store.write({
                id = "old",
                name = "Old",
                provider = "ollama",
                model = "llama3.2",
                created_at = 1700000000,
                updated_at = 1700000000,
                message_count = 1,
                messages = { { role = "user", content = "old" } },
            })
            store.write({
                id = "new",
                name = "New",
                provider = "ollama",
                model = "llama3.2",
                created_at = 1700000200,
                updated_at = 1700000200,
                message_count = 1,
                messages = { { role = "user", content = "new" } },
            })
            store.write({
                id = "mid",
                name = "Mid",
                provider = "ollama",
                model = "llama3.2",
                created_at = 1700000100,
                updated_at = 1700000100,
                message_count = 1,
                messages = { { role = "user", content = "mid" } },
            })

            local entries = store.list()
            assert.equals(3, #entries)
            assert.equals("new", entries[1].id)
            assert.equals("mid", entries[2].id)
            assert.equals("old", entries[3].id)
        end)

        it("returns metadata only (no messages)", function()
            store.write({
                id = "meta-test",
                name = "Metadata test",
                provider = "anthropic",
                model = "claude-sonnet-4-20250514",
                created_at = 1700000000,
                updated_at = 1700000000,
                message_count = 5,
                messages = {
                    { role = "user", content = "msg1" },
                    { role = "assistant", content = "msg2" },
                    { role = "user", content = "msg3" },
                    { role = "assistant", content = "msg4" },
                    { role = "user", content = "msg5" },
                },
            })

            local entries = store.list()
            assert.equals(1, #entries)
            assert.equals("meta-test", entries[1].id)
            assert.equals("Metadata test", entries[1].name)
            assert.equals("anthropic", entries[1].provider)
            assert.equals(5, entries[1].message_count)
            -- list() should not include full messages
            assert.is_nil(entries[1].messages)
        end)
    end)

    describe("delete", function()
        it("deletes an existing conversation", function()
            store.write({
                id = "to-delete",
                name = "Delete me",
                provider = "ollama",
                model = "llama3.2",
                created_at = 1700000000,
                updated_at = 1700000000,
                message_count = 0,
                messages = {},
            })

            assert.is_not_nil(store.read("to-delete"))
            store.delete("to-delete")
            assert.is_nil(store.read("to-delete"))
        end)

        it("does not error when deleting nonexistent conversation", function()
            assert.has_no.errors(function()
                store.delete("does-not-exist")
            end)
        end)
    end)

    describe("pruning", function()
        it("prunes oldest conversations when over limit", function()
            -- Set a low limit
            store.init(test_dir, 3)

            for i = 1, 5 do
                store.write({
                    id = "prune-" .. i,
                    name = "Conversation " .. i,
                    provider = "ollama",
                    model = "llama3.2",
                    created_at = 1700000000 + i,
                    updated_at = 1700000000 + i,
                    message_count = 1,
                    messages = { { role = "user", content = "msg " .. i } },
                })
            end

            local entries = store.list()
            assert.equals(3, #entries)
            -- Should keep the 3 newest
            assert.equals("prune-5", entries[1].id)
            assert.equals("prune-4", entries[2].id)
            assert.equals("prune-3", entries[3].id)
        end)
    end)

    describe("corrupt file handling", function()
        it("returns nil for corrupt JSON file", function()
            -- Write garbage to a file
            local filepath = test_dir .. "/corrupt-id.json"
            vim.fn.writefile({ "this is not valid json {{{" }, filepath)

            local loaded = store.read("corrupt-id")
            assert.is_nil(loaded)
        end)

        it("skips corrupt files in list()", function()
            -- Write a valid entry
            store.write({
                id = "valid",
                name = "Valid",
                provider = "ollama",
                model = "llama3.2",
                created_at = 1700000000,
                updated_at = 1700000000,
                message_count = 1,
                messages = { { role = "user", content = "valid" } },
            })

            -- Write a corrupt file
            local filepath = test_dir .. "/corrupt.json"
            vim.fn.writefile({ "not json" }, filepath)

            local entries = store.list()
            assert.equals(1, #entries)
            assert.equals("valid", entries[1].id)
        end)

        it("handles empty file gracefully", function()
            local filepath = test_dir .. "/empty.json"
            vim.fn.writefile({}, filepath)

            local loaded = store.read("empty")
            assert.is_nil(loaded)
        end)
    end)
end)
