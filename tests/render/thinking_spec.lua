--- Tests for thinking block rendering in ai-chat.ui.render
local render = require("ai-chat.ui.render")

describe("thinking block rendering", function()
    local ns = vim.api.nvim_create_namespace("ai-chat-render")

    it("applies AiChatThinking highlight to <thinking> blocks", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].modifiable = false

        render.render_message(buf, {
            role = "assistant",
            content = "<thinking>\nLet me reason about this...\nOkay I see.\n</thinking>\nThe answer is 42.",
            context = {},
        })

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        -- Find the <thinking> line
        local thinking_line = nil
        for i, line in ipairs(lines) do
            if line:match("^<thinking>") then
                thinking_line = i - 1
                break
            end
        end
        assert(thinking_line, "should find <thinking> tag line")

        -- Check that thinking lines have the AiChatThinking highlight
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { thinking_line, 0 }, { thinking_line, -1 }, { details = true })
        local has_thinking_hl = false
        for _, mark in ipairs(marks) do
            local details = mark[4]
            if details.line_hl_group == "AiChatThinking" then
                has_thinking_hl = true
            end
        end
        assert(has_thinking_hl, "thinking line should have AiChatThinking highlight")

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("applies AiChatThinking highlight to <think> blocks (Ollama variant)", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].modifiable = false

        render.render_message(buf, {
            role = "assistant",
            content = "<think>\nReasoning here...\n</think>\nFinal answer.",
            context = {},
        })

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local think_line = nil
        for i, line in ipairs(lines) do
            if line:match("^<think>") then
                think_line = i - 1
                break
            end
        end
        assert(think_line, "should find <think> tag line")

        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { think_line, 0 }, { think_line, -1 }, { details = true })
        local has_thinking_hl = false
        for _, mark in ipairs(marks) do
            local details = mark[4]
            if details.line_hl_group == "AiChatThinking" then
                has_thinking_hl = true
            end
        end
        assert(has_thinking_hl, "think line should have AiChatThinking highlight")

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("applies overlay extmark to conceal opening tag", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].modifiable = false

        render.render_message(buf, {
            role = "assistant",
            content = "<thinking>\nSome thought\n</thinking>\nResult.",
            context = {},
        })

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local thinking_line = nil
        for i, line in ipairs(lines) do
            if line:match("^<thinking>") then
                thinking_line = i - 1
                break
            end
        end
        assert(thinking_line, "should find <thinking> tag line")

        -- Check for overlay virtual text on the opening tag line
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { thinking_line, 0 }, { thinking_line, -1 }, { details = true })
        local has_overlay = false
        for _, mark in ipairs(marks) do
            local details = mark[4]
            if details.virt_text_pos == "overlay" then
                has_overlay = true
            end
        end
        assert(has_overlay, "opening tag should have overlay virtual text")

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does not apply thinking highlights to normal text", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].modifiable = false

        render.render_message(buf, {
            role = "assistant",
            content = "No thinking here, just a normal response.",
            context = {},
        })

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        -- Check that no line has AiChatThinking highlight
        for i = 0, #lines - 1 do
            local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { i, 0 }, { i, -1 }, { details = true })
            for _, mark in ipairs(marks) do
                local details = mark[4]
                assert(details.line_hl_group ~= "AiChatThinking",
                    "normal text should NOT have AiChatThinking highlight")
            end
        end

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("renders thinking blocks in streamed responses", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].modifiable = false

        local stream = render.begin_response(buf)

        -- Simulate streaming with thinking
        stream.append("<thinking>\n")
        vim.wait(10) -- Allow vim.schedule to process
        stream.append("reasoning step 1\n")
        vim.wait(10)
        stream.append("reasoning step 2\n")
        vim.wait(10)
        stream.append("</thinking>\n")
        vim.wait(10)
        stream.append("The answer is 42.")
        vim.wait(10)
        stream.finish({ input_tokens = 100, output_tokens = 50 })
        vim.wait(50) -- Allow finish() schedule to process

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        -- The buffer should contain thinking tags and content
        local found_thinking_open = false
        local found_answer = false
        for _, line in ipairs(lines) do
            if line:match("<thinking>") then found_thinking_open = true end
            if line:match("answer is 42") then found_answer = true end
        end
        assert(found_thinking_open, "should contain thinking tag")
        assert(found_answer, "should contain the answer text")

        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)

describe("foldtext", function()
    it("returns a formatted string with line count", function()
        -- Mock vim.v values
        vim.v.foldstart = 5
        vim.v.foldend = 15
        local result = render.foldtext()
        assert.truthy(result:match("Thinking"))
        assert.truthy(result:match("9 lines"))
    end)
end)
