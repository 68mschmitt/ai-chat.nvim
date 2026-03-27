--- Tests for ai-chat.proposals — Data model, CRUD, state transitions
local proposals = require("ai-chat.proposals")

describe("proposals", function()
    before_each(function()
        proposals.clear()
    end)

    describe("add", function()
        it("adds a proposal and returns an id", function()
            local id = proposals.add({
                file = "/tmp/test.lua",
                description = "Add nil guard",
                original_lines = { "local x = opts.value" },
                proposed_lines = { "local x = opts and opts.value or nil" },
                range = { start = 10, end_ = 10 },
                conversation_id = "conv-1",
            })
            assert.is_not_nil(id)
            assert.equals("string", type(id))
        end)

        it("sets status to pending", function()
            local id = proposals.add({
                file = "/tmp/test.lua",
                description = "Fix",
                original_lines = { "a" },
                proposed_lines = { "b" },
                range = { start = 1, end_ = 1 },
                conversation_id = "conv-1",
            })
            local p = proposals.get(id)
            assert.is_not_nil(p)
            assert.equals("pending", p.status)
        end)

        it("sets created_at timestamp", function()
            local before = os.time()
            local id = proposals.add({
                file = "/tmp/test.lua",
                description = "Fix",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "conv-1",
            })
            local p = proposals.get(id)
            assert.is_not_nil(p)
            assert(p.created_at >= before, "created_at should be >= time before add")
        end)
    end)

    describe("get", function()
        it("returns nil for unknown id", function()
            assert.is_nil(proposals.get("nonexistent"))
        end)

        it("returns the correct proposal", function()
            local id1 = proposals.add({
                file = "/tmp/a.lua",
                description = "A",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            proposals.add({
                file = "/tmp/b.lua",
                description = "B",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            local p = proposals.get(id1)
            assert.equals("A", p.description)
        end)
    end)

    describe("get_at_cursor", function()
        it("finds pending proposal matching buffer and line", function()
            local id = proposals.add({
                file = "/tmp/test.lua",
                description = "Fix range",
                original_lines = { "a", "b", "c" },
                proposed_lines = { "x", "y", "z" },
                range = { start = 10, end_ = 12 },
                conversation_id = "c",
                bufnr = 42,
            })
            local p = proposals.get_at_cursor(42, 11) -- line 11 is within 10-12
            assert.is_not_nil(p)
            assert.equals(id, p.id)
        end)

        it("returns nil when line is outside range", function()
            proposals.add({
                file = "/tmp/test.lua",
                description = "Fix",
                original_lines = { "a" },
                proposed_lines = { "b" },
                range = { start = 10, end_ = 12 },
                conversation_id = "c",
                bufnr = 42,
            })
            assert.is_nil(proposals.get_at_cursor(42, 5))
            assert.is_nil(proposals.get_at_cursor(42, 13))
        end)

        it("returns nil for wrong buffer", function()
            proposals.add({
                file = "/tmp/test.lua",
                description = "Fix",
                original_lines = {},
                proposed_lines = {},
                range = { start = 10, end_ = 12 },
                conversation_id = "c",
                bufnr = 42,
            })
            assert.is_nil(proposals.get_at_cursor(99, 11))
        end)

        it("skips rejected proposals, falls back to expired", function()
            local id1 = proposals.add({
                file = "/tmp/test.lua",
                description = "Rejected",
                original_lines = {},
                proposed_lines = {},
                range = { start = 10, end_ = 12 },
                conversation_id = "c",
                bufnr = 42,
            })
            proposals.reject(id1)

            local id2 = proposals.add({
                file = "/tmp/test.lua",
                description = "Expired",
                original_lines = {},
                proposed_lines = {},
                range = { start = 10, end_ = 12 },
                conversation_id = "c",
                bufnr = 42,
            })
            proposals.expire(id2)

            local p = proposals.get_at_cursor(42, 11)
            assert.is_not_nil(p)
            assert.equals(id2, p.id)
            assert.equals("expired", p.status)
        end)
    end)

    describe("get_pending", function()
        it("returns only pending proposals", function()
            proposals.add({
                file = "/tmp/a.lua",
                description = "A",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            local id2 = proposals.add({
                file = "/tmp/b.lua",
                description = "B",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            proposals.reject(id2)

            local pending = proposals.get_pending()
            assert.equals(1, #pending)
            assert.equals("A", pending[1].description)
        end)
    end)

    describe("get_for_file", function()
        it("returns proposals for a specific file path", function()
            proposals.add({
                file = "/tmp/a.lua",
                description = "A",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            proposals.add({
                file = "/tmp/b.lua",
                description = "B",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })

            local result = proposals.get_for_file("/tmp/a.lua")
            assert.equals(1, #result)
            assert.equals("A", result[1].description)
        end)

        it("works for proposals without bufnr", function()
            proposals.add({
                file = "/tmp/unloaded.lua",
                description = "Unloaded",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 5 },
                conversation_id = "c",
                -- no bufnr
            })
            local result = proposals.get_for_file("/tmp/unloaded.lua")
            assert.equals(1, #result)
        end)
    end)

    describe("state transitions", function()
        it("accept changes status", function()
            local id = proposals.add({
                file = "/tmp/test.lua",
                description = "Fix",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            local p = proposals.accept(id)
            assert.equals("accepted", p.status)
        end)

        it("reject changes status", function()
            local id = proposals.add({
                file = "/tmp/test.lua",
                description = "Fix",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            local p = proposals.reject(id)
            assert.equals("rejected", p.status)
        end)

        it("expire changes status", function()
            local id = proposals.add({
                file = "/tmp/test.lua",
                description = "Fix",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            local p = proposals.expire(id)
            assert.equals("expired", p.status)
        end)

        it("returns nil for unknown id", function()
            assert.is_nil(proposals.accept("nope"))
            assert.is_nil(proposals.reject("nope"))
            assert.is_nil(proposals.expire("nope"))
        end)
    end)

    describe("count_pending", function()
        it("counts only pending proposals", function()
            proposals.add({
                file = "/tmp/a.lua",
                description = "A",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            local id2 = proposals.add({
                file = "/tmp/b.lua",
                description = "B",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            proposals.add({
                file = "/tmp/c.lua",
                description = "C",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            proposals.reject(id2)

            assert.equals(2, proposals.count_pending())
        end)
    end)

    describe("clear", function()
        it("removes all proposals", function()
            proposals.add({
                file = "/tmp/test.lua",
                description = "Fix",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
            })
            proposals.clear()
            assert.equals(0, #proposals.all())
            assert.equals(0, proposals.count_pending())
        end)
    end)

    describe("has_pending", function()
        it("returns true when buffer has pending proposals", function()
            proposals.add({
                file = "/tmp/test.lua",
                description = "Fix",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
                bufnr = 42,
            })
            assert.is_true(proposals.has_pending(42))
        end)

        it("returns false when no pending proposals for buffer", function()
            local id = proposals.add({
                file = "/tmp/test.lua",
                description = "Fix",
                original_lines = {},
                proposed_lines = {},
                range = { start = 1, end_ = 1 },
                conversation_id = "c",
                bufnr = 42,
            })
            proposals.reject(id)
            assert.is_false(proposals.has_pending(42))
        end)

        it("returns false for unknown buffer", function()
            assert.is_false(proposals.has_pending(999))
        end)
    end)
end)
