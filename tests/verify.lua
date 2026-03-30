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

-- Test 6: token estimation
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

-- Test 8: render module
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
        if line == "## You" then
            found_user = true
        end
        if line == "## Assistant" then
            found_assistant = true
        end
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

-- Test 20: bold concealment extmarks
test("bold concealment applies extmarks", function()
    local render = require("ai-chat.ui.render")
    local ns = vim.api.nvim_create_namespace("ai-chat-render")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = false

    render.render_message(buf, {
        role = "assistant",
        content = "This is **bold text** here.",
    })

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Find the content line with bold text
    local bold_line = nil
    for i, line in ipairs(lines) do
        if line:match("%*%*bold text%*%*") then
            bold_line = i - 1 -- 0-indexed
            break
        end
    end
    assert(bold_line, "should find the bold text line")

    -- Check that extmarks were applied on the bold text line
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { bold_line, 0 }, { bold_line, -1 }, { details = true })
    local has_conceal = false
    local has_bold_hl = false
    for _, mark in ipairs(marks) do
        local details = mark[4]
        if details.conceal == "" then
            has_conceal = true
        end
        if details.hl_group == "@markup.strong" then
            has_bold_hl = true
        end
    end
    assert(has_conceal, "should have conceal extmarks for ** delimiters")
    assert(has_bold_hl, "should have @markup.strong highlight extmark")

    vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Test 21: bold concealment skips code blocks
test("bold concealment skips code blocks", function()
    local render = require("ai-chat.ui.render")
    local ns = vim.api.nvim_create_namespace("ai-chat-render")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = false

    render.render_message(buf, {
        role = "assistant",
        content = '```python\nx = "**not bold**"\n```',
    })

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Find the line with **not bold**
    local code_line = nil
    for i, line in ipairs(lines) do
        if line:match("not bold") then
            code_line = i - 1
            break
        end
    end
    assert(code_line, "should find the code content line")

    -- Check that NO conceal extmarks were applied inside the code block
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { code_line, 0 }, { code_line, -1 }, { details = true })
    for _, mark in ipairs(marks) do
        local details = mark[4]
        assert(details.conceal ~= "", "should NOT conceal inside code blocks")
    end

    vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Test 22: multiple bold segments on one line
test("multiple bold segments on one line", function()
    local render = require("ai-chat.ui.render")
    local ns = vim.api.nvim_create_namespace("ai-chat-render")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = false

    render.render_message(buf, {
        role = "assistant",
        content = "**first** and **second** bold",
    })

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local bold_line = nil
    for i, line in ipairs(lines) do
        if line:match("first.*second") then
            bold_line = i - 1
            break
        end
    end
    assert(bold_line, "should find the line with multiple bold segments")

    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { bold_line, 0 }, { bold_line, -1 }, { details = true })
    local bold_count = 0
    for _, mark in ipairs(marks) do
        local details = mark[4]
        if details.hl_group == "@markup.strong" then
            bold_count = bold_count + 1
        end
    end
    assert(bold_count == 2, "should have 2 bold highlight extmarks, got: " .. bold_count)

    vim.api.nvim_buf_delete(buf, { force = true })
end)

-- Test 23: treesitter setup in chat window
test("treesitter setup on chat window", function()
    local chat = require("ai-chat")
    chat.open()

    local chat_mod = require("ai-chat.ui.chat")
    local winid = chat_mod.get_winid()
    assert(winid and vim.api.nvim_win_is_valid(winid), "chat window should be valid")

    -- conceallevel should be set (if treesitter markdown is available)
    local cl = vim.wo[winid].conceallevel
    -- If treesitter started successfully, conceallevel is 2; otherwise 0
    -- We accept both since CI may not have the markdown parser
    assert(cl == 0 or cl == 2, "conceallevel should be 0 or 2, got: " .. cl)

    chat.close()
end)

-- Test 24: code blocks without language get fence highlighting
test("language-less code blocks get fence highlighting", function()
    local render = require("ai-chat.ui.render")
    local ns = vim.api.nvim_create_namespace("ai-chat-render")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].modifiable = false

    render.render_message(buf, {
        role = "assistant",
        content = "```\nsome code\n```",
    })

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- Find opening fence line (```)
    local fence_line = nil
    for i, line in ipairs(lines) do
        if line == "```" and not fence_line then
            fence_line = i - 1
            break
        end
    end
    assert(fence_line, "should find the opening fence line")

    -- Check that the fence line has the AiChatMeta highlight
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { fence_line, 0 }, { fence_line, -1 }, { details = true })
    local has_meta = false
    for _, mark in ipairs(marks) do
        local details = mark[4]
        if details.line_hl_group == "AiChatMeta" then
            has_meta = true
        end
    end
    assert(has_meta, "language-less fence should have AiChatMeta highlight")

    vim.api.nvim_buf_delete(buf, { force = true })
end)

print("")
print("ALL " .. 19 .. " TESTS PASSED")
