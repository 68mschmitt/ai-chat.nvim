--- ai-chat.nvim — Slash command definitions
--- Each command is a function(args, state) where args is the string after the command name.

local M = {}

M.commands = {}

--- /clear — Clear conversation, start fresh.
M.commands.clear = function(args, state)
    require("ai-chat").clear()
    vim.notify("[ai-chat] Conversation cleared", vim.log.levels.INFO)
end

--- /new — Save current conversation and start a new one.
M.commands.new = function(args, state)
    local conv = state.conversation
    local msg_count = conv.messages and #conv.messages or 0
    if msg_count > 0 then
        require("ai-chat").save()
    end
    require("ai-chat").clear()
    vim.notify("[ai-chat] New conversation started", vim.log.levels.INFO)
end

--- /model [name] — Switch model. Shows picker if no name given.
M.commands.model = function(args, state)
    if args and args ~= "" then
        require("ai-chat").set_model(args)
    else
        require("ai-chat").set_model(nil) -- Opens picker
    end
end

--- /provider [name] — Switch provider. Shows picker if no name given.
M.commands.provider = function(args, state)
    if args and args ~= "" then
        require("ai-chat").set_provider(args)
    else
        require("ai-chat").set_provider(nil) -- Opens picker
    end
end

--- /context — Show current context details.
M.commands.context = function(args, state)
    local context = require("ai-chat.context")
    local available = context.available()

    local lines = { "Available context types:" }
    for _, name in ipairs(available) do
        table.insert(lines, "  @" .. name)
    end
    table.insert(lines, "")
    table.insert(lines, "Usage: type @context_name in your message")
    table.insert(lines, "Example: @buffer How do I fix this?")

    M._render_system_message(table.concat(lines, "\n"))
end

--- /save [name] — Save the current conversation.
M.commands.save = function(args, state)
    local name = (args and args ~= "") and args or nil
    require("ai-chat").save(name)
    vim.notify("[ai-chat] Conversation saved", vim.log.levels.INFO)
end

--- /load — Browse and load saved conversations.
M.commands.load = function(args, state)
    require("ai-chat").history()
end

--- /thinking [on|off|show|hide] — Toggle thinking mode or visibility.
--- on/off: toggle whether thinking is requested from the provider.
--- show/hide: toggle whether thinking blocks are visible in the chat buffer.
M.commands.thinking = function(args, state)
    if args == "show" or args == "hide" then
        local visible = args == "show"
        require("ai-chat.config").set("chat.show_thinking", visible)
        -- Toggle visibility on the current chat buffer
        local chat = require("ai-chat.ui.chat")
        local bufnr = chat.get_bufnr()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            require("ai-chat.ui.thinking").set_visible(bufnr, visible)
        end
        vim.notify("[ai-chat] Thinking blocks: " .. (visible and "visible" or "hidden"), vim.log.levels.INFO)
        return
    end

    local value
    if args == "on" then
        value = true
    elseif args == "off" then
        value = false
    else
        -- Toggle: read current state from the coordinator
        local chat = require("ai-chat")
        local cfg = chat.get_config()
        value = not cfg.chat.thinking
    end

    require("ai-chat").set_thinking(value)
end

-- ─── Prompt Templates ────────────────────────────────────────────────
-- These commands prepend a prompt template to the user's optional extra
-- instructions, then send through the normal pipeline. Context (@buffer,
-- @selection, etc.) is collected from the user's message as usual.

--- Build a template command: collects context, prepends prompt, sends.
---@param template string  The base prompt template
---@param default_context string  Default context tag if user provides none (e.g., "@buffer")
---@param args string  User args after the command
local function send_template(template, default_context, args)
    local text = template
    if args and args ~= "" then
        -- Check if user provided context tags; if not, prepend default
        if not args:match("^@") then
            text = default_context .. " " .. text .. "\n\n" .. args
        else
            text = text .. "\n\n" .. args
        end
    else
        text = default_context .. " " .. text
    end
    require("ai-chat").send(text)
end

--- /explain — Explain the attached code.
M.commands.explain = function(args, state)
    send_template(
        "Explain the attached code. Focus on:\n"
            .. "1. What it does (behavior, not line-by-line narration)\n"
            .. "2. Why it's structured this way (design intent)\n"
            .. "3. Non-obvious details (edge cases, implicit assumptions, gotchas)\n\n"
            .. "Be concise. Skip obvious things.",
        "@buffer",
        args
    )
end

--- /fix — Identify problems and provide a fix.
M.commands.fix = function(args, state)
    send_template(
        "The attached code has a problem. Identify the issue and provide a fix.\n\n"
            .. "1. State the problem in one sentence\n"
            .. "2. Show the corrected code in a fenced code block\n"
            .. "3. Explain what was wrong and why the fix works\n\n"
            .. "If there are multiple issues, address the most critical one first.",
        "@buffer @diagnostics",
        args
    )
end

--- /test — Generate tests for the attached code.
M.commands.test = function(args, state)
    send_template(
        "Write tests for the attached code.\n\n"
            .. "- Match the testing style already present in the project if visible from context\n"
            .. "- Cover: happy path, edge cases, error conditions\n"
            .. "- Each test should have a clear name describing what it verifies\n"
            .. "- Use fenced code blocks with the appropriate language",
        "@buffer",
        args
    )
end

--- /review — Code review the attached code.
M.commands.review = function(args, state)
    send_template(
        "Review the attached code. Provide feedback on:\n\n"
            .. "1. Bugs or correctness issues (highest priority)\n"
            .. "2. Edge cases that aren't handled\n"
            .. "3. Readability or maintainability concerns\n"
            .. "4. Performance issues (only if significant)\n\n"
            .. "For each issue, quote the relevant code and suggest a specific improvement. "
            .. "Skip praise — focus on what needs to change.",
        "@diff",
        args
    )
end

--- /debug — Show the last request payload for transparency/debugging.
--- Displays: provider, model, message count, token estimates, context,
--- truncation info, and the full messages array.
M.commands.debug = function(args, state)
    local pipeline = require("ai-chat.pipeline")
    local last = pipeline.get_last_request()

    if not last or not last.provider_messages then
        M._render_system_message("No requests sent yet in this session.")
        return
    end

    local tokens = require("ai-chat.util.tokens")
    local lines = {
        "ai-chat.nvim — Last Request Debug Info",
        string.rep("-", 50),
        "",
        string.format("  Provider:     %s", last.provider or "unknown"),
        string.format("  Model:        %s", last.model or "unknown"),
        string.format("  Timestamp:    %s", last.timestamp and os.date("%Y-%m-%d %H:%M:%S", last.timestamp) or "n/a"),
        string.format("  Messages:     %d", last.provider_messages and #last.provider_messages or 0),
    }

    -- Options
    if last.opts then
        table.insert(lines, string.format("  Temperature:  %s", tostring(last.opts.temperature or "default")))
        table.insert(lines, string.format("  Max tokens:   %s", tostring(last.opts.max_tokens or "default")))
        table.insert(lines, string.format("  Thinking:     %s", tostring(last.opts.thinking or false)))
    end

    -- Truncation
    if last.truncated then
        table.insert(lines, string.format("  Truncated:    %d messages dropped", last.truncated))
    else
        table.insert(lines, "  Truncated:    no")
    end

    -- Context
    if last.context and #last.context > 0 then
        table.insert(lines, "")
        table.insert(lines, "Context collected:")
        for _, ctx in ipairs(last.context) do
            table.insert(lines, string.format("  @%s: %s (~%d tokens)", ctx.type, ctx.source, ctx.token_estimate or 0))
        end
    end

    -- Messages sent to provider
    table.insert(lines, "")
    table.insert(lines, "Messages sent to provider:")
    table.insert(lines, string.rep("-", 50))
    for i, msg in ipairs(last.provider_messages) do
        local token_est = tokens.estimate(msg.content)
        local preview = msg.content:sub(1, 120):gsub("\n", "\\n")
        if #msg.content > 120 then
            preview = preview .. "..."
        end
        table.insert(lines, string.format("  [%d] %s (~%d tokens)", i, msg.role, token_est))
        table.insert(lines, "      " .. preview)
        table.insert(lines, "")
    end

    -- Total token estimate
    local total_tokens = 0
    for _, msg in ipairs(last.provider_messages) do
        total_tokens = total_tokens + tokens.estimate(msg.content)
    end
    table.insert(lines, string.format("  Total: ~%d tokens (estimated)", total_tokens))

    require("ai-chat.util.ui").show_in_split(lines)
end

--- /propose — Ask the AI to propose code changes.
--- Sends with a system prompt supplement instructing structured output.
--- The response callback triggers proposal extraction via init.lua.
M.commands.propose = function(args, state)
    local propose_system = "IMPORTANT: You are being asked to propose specific code changes. "
        .. "For each change, output a fenced code block with the target file path annotation. "
        .. "Use this format on the opening fence line:\n\n"
        .. "```language file=path/to/file.lua lines=N-M\n"
        .. "-- replacement code here\n"
        .. "```\n\n"
        .. "Where:\n"
        .. "- `file=` is the relative path from the project root\n"
        .. "- `lines=N-M` is the line range being replaced (optional but preferred)\n"
        .. "- The code block content is the proposed replacement\n\n"
        .. "Before each code block, write a brief explanation (1-3 sentences) of what the change does and why it's needed. "
        .. "Code blocks without file= annotations will be treated as illustrative examples, not proposals."

    local template = propose_system .. "\n\nPropose specific code changes for the following request:"
    local default_context = "@buffer"

    local text = template
    if args and args ~= "" then
        if not args:match("^@") then
            text = default_context .. " " .. text .. "\n\n" .. args
        else
            text = text .. "\n\n" .. args
        end
    else
        text = default_context .. " " .. text
    end

    require("ai-chat").send(text, {
        callback = function(response)
            if response and response.content then
                require("ai-chat").handle_proposals(response.content)
            end
        end,
    })
end

--- /help — List available commands.
M.commands.help = function(args, state)
    local lines = {
        "ai-chat.nvim commands:",
        "",
        "  /clear            Clear conversation",
        "  /new              Save and start new conversation",
        "  /model [name]     Switch model",
        "  /provider [name]  Switch provider",
        "  /thinking [on|off|show|hide] Toggle thinking mode or visibility",
        "  /explain [text]   Explain attached code (@buffer default)",
        "  /fix [text]       Fix problems in attached code (@buffer @diagnostics)",
        "  /test [text]      Generate tests for attached code (@buffer default)",
        "  /review [text]    Code review (@diff default)",
        "  /propose [text]   Propose code changes (@buffer default)",
        "  /context          Show available context types",
        "  /save [name]      Save conversation",
        "  /load             Browse saved conversations",
        "  /debug            Show last request payload (messages, tokens, context)",
        "  /help             Show this help",
    }

    M._render_system_message(table.concat(lines, "\n"))
end

--- Render a system-level message in the chat buffer.
--- Falls back to vim.notify if the panel is not open.
---@param text string
function M._render_system_message(text)
    local ai_chat = require("ai-chat")
    if ai_chat.is_open() then
        local chat = require("ai-chat.ui.chat")
        local bufnr = chat.get_bufnr()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            require("ai-chat.ui.render").render_message(bufnr, {
                role = "assistant",
                content = text,
            })
            return
        end
    end
    vim.notify(text, vim.log.levels.INFO)
end

--- List all command names (for completion).
---@return string[]
function M.list()
    return vim.tbl_keys(M.commands)
end

return M
