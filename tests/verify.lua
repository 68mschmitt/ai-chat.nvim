-- End-to-end verification tests for ai-chat.nvim v0.1
-- Run: nvim --headless --clean -u tests/minimal_init.lua -l tests/verify.lua

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        print("PASS: " .. name)
    else
        print("FAIL: " .. name .. " -- " .. tostring(err))
        os.exit(1)
    end
end

-- Test 1: config resolved
test("config resolved correctly", function()
    local chat = require("ai-chat")
    local cfg = chat.get_config()
    assert(cfg.default_provider == "ollama", "provider should be ollama")
    assert(cfg.default_model == "llama3.2", "model should be llama3.2")
end)

-- Test 2: open/close
test("open and close", function()
    local chat = require("ai-chat")
    assert(not chat.is_open(), "should start closed")
    chat.open()
    assert(chat.is_open(), "should be open after open()")
    chat.close()
    assert(not chat.is_open(), "should be closed after close()")
end)

-- Test 3: toggle
test("toggle", function()
    local chat = require("ai-chat")
    chat.toggle()
    assert(chat.is_open(), "should be open after toggle")
    chat.toggle()
    assert(not chat.is_open(), "should be closed after second toggle")
end)

-- Test 4: conversation state
test("conversation state", function()
    local chat = require("ai-chat")
    local conv = chat.get_conversation()
    assert(conv.provider == "ollama", "conv provider should be ollama")
    assert(conv.model == "llama3.2", "conv model should be llama3.2")
    assert(#conv.messages == 0, "conv should start empty")
end)

-- Test 5: clear
test("clear conversation", function()
    local chat = require("ai-chat")
    chat.clear()
    local conv = chat.get_conversation()
    assert(#conv.messages == 0, "conv should be empty after clear")
end)

-- Test 6: context tag parsing
test("context tag parsing", function()
    local ctx = require("ai-chat.context")
    local tags = ctx._parse_tags("@buffer How do I fix this?")
    assert(#tags == 1, "should find one tag")
    assert(tags[1].name == "buffer", "tag should be buffer")
end)

-- Test 7: multiple tags
test("multiple context tags", function()
    local ctx = require("ai-chat.context")
    local tags = ctx._parse_tags("@buffer @selection fix errors")
    assert(#tags == 2, "should find two tags")
    assert(tags[1].name == "buffer")
    assert(tags[2].name == "selection")
end)

-- Test 8: file tag with path
test("file tag with path", function()
    local ctx = require("ai-chat.context")
    local tags = ctx._parse_tags("@file:src/main.lua explain this")
    assert(#tags == 1, "should find one tag")
    assert(tags[1].name == "file")
    assert(tags[1].args == "src/main.lua")
end)

-- Test 9: strip tags
test("tag stripping", function()
    local ctx = require("ai-chat.context")
    local stripped = ctx.strip_tags("@buffer @selection How do I fix this?")
    assert(stripped == "How do I fix this?", "got: " .. stripped)
end)

-- Test 10: token estimation
test("token estimation", function()
    local tokens = require("ai-chat.util.tokens")
    local count = tokens.estimate("hello world foo bar")
    assert(count > 0, "should estimate > 0 tokens")
    assert(count < 100, "should be reasonable for 4 words")
end)

-- Test 11: cost estimation
test("cost estimation ollama free", function()
    local costs = require("ai-chat.util.costs")
    local cost = costs.estimate("ollama", "llama3.2", { input_tokens = 100, output_tokens = 200 })
    assert(cost == 0, "ollama should be free")
end)

-- Test 12: slash commands exist
test("slash commands registered", function()
    local slash = require("ai-chat.commands.slash")
    assert(slash.commands.clear, "/clear should exist")
    assert(slash.commands.help, "/help should exist")
    assert(slash.commands.model, "/model should exist")
    assert(slash.commands.provider, "/provider should exist")
    assert(slash.commands.save, "/save should exist")
end)

-- Test 13: render module
test("render module loads", function()
    local render = require("ai-chat.ui.render")
    assert(render.render_message, "render_message should exist")
    assert(render.begin_response, "begin_response should exist")
    assert(render.get_code_block_at_cursor, "get_code_block_at_cursor should exist")
    assert(render.clear, "clear should exist")
end)

-- Test 14: provider module
test("provider module loads", function()
    local providers = require("ai-chat.providers")
    local ollama = providers.get("ollama")
    assert(ollama, "ollama provider should load")
    assert(ollama.chat, "ollama should have chat()")
    assert(ollama.list_models, "ollama should have list_models()")
    assert(ollama.validate, "ollama should have validate()")
end)

-- Test 15: render to buffer
test("render message to buffer", function()
    local render = require("ai-chat.ui.render")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = false -- render_message should handle this

    render.render_message(buf, {
        role = "user",
        content = "Hello, how do I fix this?",
        context = {},
    })

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert(#lines >= 2, "should have at least 2 lines (header + content)")
    assert(lines[1] == "## You", "first line should be header, got: " .. lines[1])
    assert(lines[2] == "Hello, how do I fix this?", "second line should be content")

    vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Test 16: render conversation
test("render full conversation", function()
    local render = require("ai-chat.ui.render")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = false

    render.render_conversation(buf, {
        messages = {
            { role = "user", content = "Hello" },
            { role = "assistant", content = "Hi there!" },
        },
    })

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local found_user = false
    local found_assistant = false
    for _, line in ipairs(lines) do
        if line == "## You" then found_user = true end
        if line == "## Assistant" then found_assistant = true end
    end
    assert(found_user, "should contain ## You")
    assert(found_assistant, "should contain ## Assistant")

    vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Test 17: code block detection
test("code block detection", function()
    local render = require("ai-chat.ui.render")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "Some text",
        "```lua",
        "local x = 42",
        "print(x)",
        "```",
        "More text",
    })
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)

    -- Position cursor inside the code block (line 3, 1-indexed)
    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    local block = render.get_code_block_at_cursor(buf, win)
    assert(block, "should find code block")
    assert(block.language == "lua", "language should be lua, got: " .. tostring(block.language))
    assert(block.content == "local x = 42\nprint(x)", "content mismatch, got: " .. block.content)

    -- Position cursor outside the code block
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    block = render.get_code_block_at_cursor(buf, win)
    assert(not block, "should not find code block outside")

    vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Test 18: set model
test("set model directly", function()
    local chat = require("ai-chat")
    chat.set_model("codellama")
    local conv = chat.get_conversation()
    assert(conv.model == "codellama", "model should be codellama, got: " .. conv.model)
    -- Reset
    chat.set_model("llama3.2")
end)

-- Test 19: UI open creates proper window layout
test("UI creates proper layout", function()
    local chat = require("ai-chat")
    chat.open()
    assert(chat.is_open(), "should be open")

    -- Should have at least 3 windows (original + chat + input)
    local wins = vim.api.nvim_list_wins()
    assert(#wins >= 3, "should have at least 3 windows, got: " .. #wins)

    chat.close()
    -- After close, should have fewer windows
    local wins_after = vim.api.nvim_list_wins()
    assert(#wins_after < #wins, "should have fewer windows after close")
end)

print("")
print("ALL " .. 19 .. " TESTS PASSED")
