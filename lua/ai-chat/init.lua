--- ai-chat.nvim — Main module
--- Public API and module coordinator.
--- All user-facing functions live here. Internal modules are accessed
--- through this coordinator, never directly by the user.

local M = {}

---@class AiChatState
local state = {
    config = {},
    conversation = {
        id = "",
        messages = {},
        provider = "",
        model = "",
        created_at = 0,
    },
    ui = {
        chat_bufnr = nil,
        chat_winid = nil,
        input_bufnr = nil,
        input_winid = nil,
        is_open = false,
    },
    streaming = {
        active = false,
        cancel_fn = nil,
    },
}

local initialized = false

--- Initialize the plugin. Must be called once in the user's config.
---@param opts? table  User configuration (merged with defaults)
function M.setup(opts)
    local config = require("ai-chat.config")
    state.config = config.resolve(opts or {})

    local ok, err = config.validate(state.config)
    if not ok then
        vim.notify("[ai-chat] Configuration error: " .. err, vim.log.levels.ERROR)
        return
    end

    -- Set up highlight groups first (other modules may reference them)
    M._setup_highlights()

    -- Set up global keybindings
    M._setup_keymaps()

    -- Initialize history if enabled
    if state.config.history.enabled then
        require("ai-chat.history").init(state.config.history)
    end

    -- Initialize logging
    require("ai-chat.util.log").init(state.config.log)

    -- Start a new conversation
    M._new_conversation()

    initialized = true
end

--- Toggle the chat panel open/closed.
function M.toggle()
    M._ensure_init()
    if state.ui.is_open then
        M.close()
    else
        M.open()
    end
end

--- Open the chat panel.
function M.open()
    M._ensure_init()
    if state.ui.is_open then return end

    local ui = require("ai-chat.ui")
    local result = ui.open(state.config.ui, state.conversation)
    state.ui.chat_bufnr = result.chat_bufnr
    state.ui.chat_winid = result.chat_winid
    state.ui.input_bufnr = result.input_bufnr
    state.ui.input_winid = result.input_winid
    state.ui.is_open = true

    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AiChatPanelOpened",
        data = { winid = state.ui.chat_winid, bufnr = state.ui.chat_bufnr },
    })
end

--- Close the chat panel.
function M.close()
    if not state.ui.is_open then return end

    -- Cancel any active generation
    if state.streaming.active then
        M.cancel()
    end

    require("ai-chat.ui").close()
    state.ui.is_open = false
    state.ui.chat_winid = nil
    state.ui.input_winid = nil
    state.ui.chat_bufnr = nil
    state.ui.input_bufnr = nil

    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatPanelClosed" })
end

--- Returns whether the chat panel is currently open.
---@return boolean
function M.is_open()
    return state.ui.is_open
end

--- Send a message to the AI.
---@param text? string  Message text. If nil, uses current input buffer content.
---@param opts? { context?: string[], callback?: fun(response: AiChatResponse) }
function M.send(text, opts)
    M._ensure_init()
    opts = opts or {}

    -- Get text from input buffer if not provided
    if not text then
        text = require("ai-chat.ui.input").get_text()
    end

    if not text or text == "" then return end

    -- Open panel if not open
    if not state.ui.is_open then
        M.open()
    end

    -- Check for slash commands
    if text:match("^/") then
        require("ai-chat.commands").handle(text, state)
        -- Clear the input after handling slash command
        if state.ui.is_open then
            require("ai-chat.ui.input").clear()
        end
        return
    end

    -- Don't send while already streaming
    if state.streaming.active then
        vim.notify("[ai-chat] Already generating a response. Press <C-c> to cancel.", vim.log.levels.WARN)
        return
    end

    -- Collect context from @tags in the message
    local context_mod = require("ai-chat.context")
    local context = context_mod.collect(text, opts.context)

    -- Strip @tags from the display text
    local clean_text = context_mod.strip_tags(text)
    if clean_text == "" then clean_text = text end

    -- Build user message
    local message = {
        role = "user",
        content = clean_text,
        context = context,
        timestamp = os.time(),
    }

    -- Append to conversation
    table.insert(state.conversation.messages, message)

    -- Render user message in chat
    require("ai-chat.ui.render").render_message(state.ui.chat_bufnr, message)

    -- Clear input
    require("ai-chat.ui.input").clear()

    -- Build provider messages (system prompt + history + context)
    local provider_messages = M._build_provider_messages()

    -- Start streaming
    local provider = require("ai-chat.providers").get(state.conversation.provider)
    local spinner = require("ai-chat.ui.spinner")

    state.streaming.active = true
    spinner.start(state.ui.chat_winid)

    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AiChatResponseStart",
        data = { provider = state.conversation.provider, model = state.conversation.model },
    })

    -- Create stream renderer
    local stream_render = require("ai-chat.ui.render").begin_response(state.ui.chat_bufnr)

    state.streaming.cancel_fn = provider.chat(
        provider_messages,
        {
            model = state.conversation.model,
            temperature = state.config.chat.temperature,
            max_tokens = state.config.chat.max_tokens,
            thinking = state.config.chat.thinking,
        },
        {
            on_chunk = function(chunk_text)
                stream_render.append(chunk_text)
            end,
            on_done = function(response)
                state.streaming.active = false
                state.streaming.cancel_fn = nil
                spinner.stop()

                -- Finalize rendering
                stream_render.finish(response.usage)

                -- Update winbar with new message count
                M._update_winbar()

                -- Store assistant message
                table.insert(state.conversation.messages, {
                    role = "assistant",
                    content = response.content,
                    usage = response.usage,
                    model = response.model,
                    thinking = response.thinking,
                    timestamp = os.time(),
                })

                -- Record costs
                if response.usage then
                    require("ai-chat.util.costs").record(
                        state.conversation.provider,
                        state.conversation.model,
                        response.usage
                    )
                end

                -- Auto-save conversation
                if state.config.history.enabled then
                    require("ai-chat.history").save(state.conversation)
                end

                pcall(vim.api.nvim_exec_autocmds, "User", {
                    pattern = "AiChatResponseDone",
                    data = { response = response, usage = response.usage },
                })

                -- User callback
                if opts.callback then
                    opts.callback(response)
                end
            end,
            on_error = function(err)
                state.streaming.active = false
                state.streaming.cancel_fn = nil
                spinner.stop()

                stream_render.error(err)

                require("ai-chat.util.log").error("Provider error", err)

                pcall(vim.api.nvim_exec_autocmds, "User", {
                    pattern = "AiChatResponseError",
                    data = { error = err },
                })
            end,
        }
    )
end

--- Cancel the active generation.
function M.cancel()
    if state.streaming.active and state.streaming.cancel_fn then
        state.streaming.cancel_fn()
        state.streaming.active = false
        state.streaming.cancel_fn = nil
        require("ai-chat.ui.spinner").stop()
    end
end

--- Returns whether a response is currently being streamed.
---@return boolean
function M.is_streaming()
    return state.streaming.active
end

--- Clear the current conversation and start fresh.
function M.clear()
    M._ensure_init()
    if state.streaming.active then
        M.cancel()
    end
    M._new_conversation()
    if state.ui.is_open then
        require("ai-chat.ui.render").clear(state.ui.chat_bufnr)
        M._update_winbar()
    end
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatConversationCleared" })
end

--- Get a read-only copy of the current conversation.
---@return AiChatConversation
function M.get_conversation()
    return vim.deepcopy(state.conversation)
end

--- Get the resolved configuration.
---@return AiChatConfig
function M.get_config()
    return vim.deepcopy(state.config)
end

--- Switch the active model.
---@param model_name? string  If nil, opens a picker.
function M.set_model(model_name)
    M._ensure_init()
    if model_name then
        state.conversation.model = model_name
        M._update_winbar()
        vim.notify("[ai-chat] Model: " .. model_name, vim.log.levels.INFO)
    else
        local provider = require("ai-chat.providers").get(state.conversation.provider)
        provider.list_models(
            state.config.providers[state.conversation.provider] or {},
            function(models)
                if #models == 0 then
                    vim.notify("[ai-chat] No models available from " .. state.conversation.provider, vim.log.levels.WARN)
                    return
                end
                vim.ui.select(models, { prompt = "Select model:" }, function(choice)
                    if choice then
                        M.set_model(choice)
                    end
                end)
            end
        )
    end
end

--- Switch the active provider.
---@param provider_name? string  If nil, opens a picker.
function M.set_provider(provider_name)
    M._ensure_init()
    if provider_name then
        local providers = require("ai-chat.providers")
        if not providers.exists(provider_name) then
            vim.notify("[ai-chat] Unknown provider: " .. provider_name, vim.log.levels.WARN)
            return
        end
        state.conversation.provider = provider_name
        local provider_config = state.config.providers[provider_name]
        if provider_config and provider_config.model then
            state.conversation.model = provider_config.model
        end
        M._update_winbar()
        vim.notify("[ai-chat] Provider: " .. provider_name, vim.log.levels.INFO)
        pcall(vim.api.nvim_exec_autocmds, "User", {
            pattern = "AiChatProviderChanged",
            data = { provider = provider_name, model = state.conversation.model },
        })
    else
        local available = require("ai-chat.providers").list()
        vim.ui.select(available, { prompt = "Select provider:" }, function(choice)
            if choice then
                M.set_provider(choice)
            end
        end)
    end
end

--- Save the current conversation.
---@param name? string  Optional name for the conversation.
function M.save(name)
    M._ensure_init()
    if state.config.history.enabled then
        require("ai-chat.history").save(state.conversation, name)
        vim.notify("[ai-chat] Conversation saved", vim.log.levels.INFO)
    end
end

--- Load a conversation by ID.
---@param id? string  If nil, opens a history browser.
function M.load(id)
    M._ensure_init()
    if id then
        local conv = require("ai-chat.history").load(id)
        if conv then
            state.conversation = conv
            if state.ui.is_open then
                require("ai-chat.ui.render").render_conversation(state.ui.chat_bufnr, conv)
                M._update_winbar()
            end
        end
    else
        M.history()
    end
end

--- Open the conversation history browser.
function M.history()
    M._ensure_init()
    require("ai-chat.history").browse(function(conv)
        if conv then
            M.load(conv.id)
        end
    end)
end

--- Show keybinding reference.
function M.show_keys()
    local lines = { "ai-chat.nvim Keybindings", string.rep("-", 40) }

    local sections = {
        { "Global", {
            { "toggle", "Toggle chat panel" },
            { "send_selection", "Send selection to chat" },
            { "quick_explain", "Explain selection" },
            { "quick_fix", "Fix selection" },
            { "focus_input", "Focus chat input" },
            { "switch_model", "Switch model" },
            { "switch_provider", "Switch provider" },
        }},
        { "Chat Buffer", {
            { "close", "Close panel" },
            { "cancel", "Cancel generation" },
            { "next_message", "Next message" },
            { "prev_message", "Previous message" },
            { "next_code_block", "Next code block" },
            { "prev_code_block", "Previous code block" },
            { "yank_code_block", "Yank code block" },
            { "apply_code_block", "Apply code block (diff)" },
            { "open_code_block", "Open code block in split" },
        }},
        { "Input", {
            { "submit_normal", "Send message (normal)" },
            { "submit_insert", "Send message (insert)" },
            { "recall_prev", "Previous in history" },
            { "recall_next", "Next in history" },
        }},
    }

    local keys = initialized and state.config.keys or require("ai-chat.config").defaults.keys
    for _, section in ipairs(sections) do
        table.insert(lines, "")
        table.insert(lines, section[1] .. ":")
        for _, item in ipairs(section[2]) do
            local key = keys[item[1]]
            if key then
                table.insert(lines, string.format("  %-16s %s", key, item[2]))
            end
        end
    end

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.cmd("botright " .. math.min(#lines + 2, 30) .. "split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
end

--- Show resolved configuration.
function M.show_config()
    M._ensure_init()
    -- Redact any API keys
    local display_config = vim.deepcopy(state.config)
    for _, pname in ipairs({ "anthropic", "openai_compat" }) do
        if display_config.providers[pname] and display_config.providers[pname].api_key then
            display_config.providers[pname].api_key = "***"
        end
    end

    local lines = vim.split(vim.inspect(display_config), "\n")
    table.insert(lines, 1, "ai-chat.nvim Resolved Configuration")
    table.insert(lines, 2, string.rep("-", 40))

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf })
end

-- ─── Internal ────────────────────────────────────────────────────────

function M._ensure_init()
    if not initialized then
        error("[ai-chat] Plugin not initialized. Call require('ai-chat').setup() first.")
    end
end

function M._new_conversation()
    state.conversation = {
        id = M._uuid(),
        messages = {},
        provider = state.config.default_provider,
        model = state.config.default_model,
        created_at = os.time(),
    }
end

function M._build_provider_messages()
    local messages = {}

    -- System prompt
    local system_prompt = state.config.chat.system_prompt or M._default_system_prompt()
    table.insert(messages, { role = "system", content = system_prompt })

    -- Conversation history with inlined context
    for _, msg in ipairs(state.conversation.messages) do
        local content = msg.content
        -- Inline context above the user's message
        if msg.role == "user" and msg.context and #msg.context > 0 then
            local context_parts = {}
            for _, ctx in ipairs(msg.context) do
                table.insert(context_parts, string.format(
                    "<context type=\"%s\" source=\"%s\">\n%s\n</context>",
                    ctx.type, ctx.source, ctx.content
                ))
            end
            content = table.concat(context_parts, "\n\n") .. "\n\n" .. content
        end
        table.insert(messages, { role = msg.role, content = content })
    end

    return messages
end

function M._default_system_prompt()
    return table.concat({
        "You are a helpful coding assistant embedded in a neovim editor.",
        "The user will ask questions about their code and you should provide",
        "clear, concise answers. When suggesting code changes, use fenced code",
        "blocks with the appropriate language identifier.",
        "Be direct. Avoid unnecessary preamble.",
    }, " ")
end

function M._setup_keymaps()
    local keys = state.config.keys
    local map = vim.keymap.set

    if keys.toggle then
        map("n", keys.toggle, function() M.toggle() end, { desc = "[ai-chat] Toggle panel" })
    end

    if keys.send_selection then
        map("v", keys.send_selection, function()
            -- Yank the visual selection, then send it
            vim.cmd('normal! "zy')
            local sel = vim.fn.getreg("z")
            if sel and sel ~= "" then
                M.open()
                M.send(sel, { context = { "selection" } })
            end
        end, { desc = "[ai-chat] Send selection" })
    end

    if keys.quick_explain then
        map("v", keys.quick_explain, function()
            vim.cmd('normal! "zy')
            local sel = vim.fn.getreg("z")
            if sel and sel ~= "" then
                M.open()
                M.send("Explain this code:\n\n" .. sel)
            end
        end, { desc = "[ai-chat] Explain selection" })
    end

    if keys.quick_fix then
        map("v", keys.quick_fix, function()
            vim.cmd('normal! "zy')
            local sel = vim.fn.getreg("z")
            if sel and sel ~= "" then
                M.open()
                M.send("Fix this code:\n\n" .. sel)
            end
        end, { desc = "[ai-chat] Fix selection" })
    end

    if keys.focus_input then
        map("n", keys.focus_input, function()
            M.open()
            require("ai-chat.ui.input").focus()
        end, { desc = "[ai-chat] Focus input" })
    end

    if keys.switch_model then
        map("n", keys.switch_model, function() M.set_model() end, { desc = "[ai-chat] Switch model" })
    end

    if keys.switch_provider then
        map("n", keys.switch_provider, function() M.set_provider() end, { desc = "[ai-chat] Switch provider" })
    end
end

function M._setup_highlights()
    local hl = vim.api.nvim_set_hl
    hl(0, "AiChatUser", { default = true, link = "Title" })
    hl(0, "AiChatAssistant", { default = true, link = "Statement" })
    hl(0, "AiChatMeta", { default = true, link = "Comment" })
    hl(0, "AiChatError", { default = true, link = "DiagnosticError" })
    hl(0, "AiChatWarning", { default = true, link = "DiagnosticWarn" })
    hl(0, "AiChatSpinner", { default = true, link = "DiagnosticInfo" })
    hl(0, "AiChatSeparator", { default = true, link = "WinSeparator" })
    hl(0, "AiChatInputPrompt", { default = true, link = "Question" })
    hl(0, "AiChatContextTag", { default = true, link = "Tag" })
end

function M._update_winbar()
    if state.ui.is_open and state.ui.chat_winid
        and vim.api.nvim_win_is_valid(state.ui.chat_winid) then
        require("ai-chat.ui.chat").update_winbar(
            state.ui.chat_winid,
            state.conversation
        )
    end
end

function M._uuid()
    math.randomseed(os.time() + os.clock() * 1000)
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format("%x", v)
    end)
end

return M
