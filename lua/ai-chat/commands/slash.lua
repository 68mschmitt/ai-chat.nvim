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

--- /thinking [on|off] — Toggle or set extended thinking mode.
M.commands.thinking = function(args, state)
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
            table.insert(
                lines,
                string.format("  @%s: %s (~%d tokens)", ctx.type, ctx.source, ctx.token_estimate or 0)
            )
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

--- /help — List available commands.
M.commands.help = function(args, state)
    local lines = {
        "ai-chat.nvim commands:",
        "",
        "  /clear            Clear conversation",
        "  /new              Save and start new conversation",
        "  /model [name]     Switch model",
        "  /provider [name]  Switch provider",
        "  /thinking [on|off] Toggle extended thinking mode",
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
