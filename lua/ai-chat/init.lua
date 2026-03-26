--- ai-chat.nvim — Main module
--- Public API and module coordinator.
--- All user-facing functions live here. Internal modules are accessed
--- through this coordinator, never directly by the user.

local M = {}

---@class AiChatState
---@field config AiChatConfig
---@field conversation AiChatConversation
---@field ui AiChatUIState
---@field streaming AiChatStreamState
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

    -- Set up keybindings
    M._setup_keymaps()

    -- Set up highlight groups
    M._setup_highlights()

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
    local winids = ui.open(state.config.ui, state.conversation)
    state.ui.chat_bufnr = winids.chat_bufnr
    state.ui.chat_winid = winids.chat_winid
    state.ui.input_bufnr = winids.input_bufnr
    state.ui.input_winid = winids.input_winid
    state.ui.is_open = true

    vim.api.nvim_exec_autocmds("User", {
        pattern = "AiChatPanelOpened",
        data = { winid = state.ui.chat_winid, bufnr = state.ui.chat_bufnr },
    })
end

--- Close the chat panel.
function M.close()
    M._ensure_init()
    if not state.ui.is_open then return end

    -- Cancel any active generation
    if state.streaming.active then
        M.cancel()
    end

    require("ai-chat.ui").close()
    state.ui.is_open = false
    state.ui.chat_winid = nil
    state.ui.input_winid = nil

    vim.api.nvim_exec_autocmds("User", { pattern = "AiChatPanelClosed" })
end

--- Returns whether the chat panel is currently open.
---@return boolean
function M.is_open()
    return state.ui.is_open
end

--- Send a message to the AI.
---@param text? string  Message text. If nil, uses current input buffer content.
---@param opts? { context?: table, callback?: fun(response: AiChatResponse) }
function M.send(text, opts)
    M._ensure_init()
    opts = opts or {}

    -- Get text from input buffer if not provided
    if not text then
        text = require("ai-chat.ui.input").get_text()
    end

    if not text or text == "" then return end

    -- Check for slash commands
    if text:match("^/") then
        require("ai-chat.commands").handle(text, state)
        return
    end

    -- Collect context
    local context_mod = require("ai-chat.context")
    local context = context_mod.collect(text, opts.context)

    -- Build user message
    local message = {
        role = "user",
        content = text,
        context = context,
        timestamp = os.time(),
    }

    -- Append to conversation
    table.insert(state.conversation.messages, message)

    -- Render user message in chat
    if state.ui.is_open then
        require("ai-chat.ui.render").render_message(state.ui.chat_bufnr, message)
    end

    -- Clear input
    require("ai-chat.ui.input").clear()

    -- Build provider messages (system prompt + history + context)
    local provider_messages = M._build_provider_messages()

    -- Start streaming
    local provider = require("ai-chat.providers").get(state.conversation.provider)
    local spinner = require("ai-chat.ui.spinner")

    state.streaming.active = true
    spinner.start(state.ui.chat_winid)

    vim.api.nvim_exec_autocmds("User", {
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

                vim.api.nvim_exec_autocmds("User", {
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

                vim.api.nvim_exec_autocmds("User", {
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
    end
    vim.api.nvim_exec_autocmds("User", { pattern = "AiChatConversationCleared" })
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
    else
        -- List models from the active provider and present picker
        local provider = require("ai-chat.providers").get(state.conversation.provider)
        provider.list_models(
            state.config.providers[state.conversation.provider],
            function(models)
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
        -- Reset model to provider default
        local provider_config = state.config.providers[provider_name]
        if provider_config and provider_config.model then
            state.conversation.model = provider_config.model
        end
        M._update_winbar()
        vim.api.nvim_exec_autocmds("User", {
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
    -- Display all active keybindings in a floating window
    local lines = { "ai-chat.nvim — Keybindings", "" }
    for action, key in pairs(state.config.keys) do
        if key then
            table.insert(lines, string.format("  %-20s %s", key, action))
        end
    end
    -- Show in a scratch buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_height(0, #lines + 2)
end

--- Show resolved configuration.
function M.show_config()
    M._ensure_init()
    local lines = vim.split(vim.inspect(state.config), "\n")
    table.insert(lines, 1, "ai-chat.nvim — Resolved Configuration")
    table.insert(lines, 2, "")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
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
        if msg.context and #msg.context > 0 then
            local context_parts = {}
            for _, ctx in ipairs(msg.context) do
                table.insert(context_parts, string.format(
                    "--- Context: %s (%s) ---\n%s\n--- End Context ---",
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
        map("n", keys.toggle, M.toggle, { desc = "[ai-chat] Toggle panel" })
    end
    if keys.send_selection then
        map({ "n", "v" }, keys.send_selection, function()
            M.open()
            -- Get visual selection and send
            local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
            if lines and #lines > 0 then
                M.send(table.concat(lines, "\n"), { context = { "selection" } })
            end
        end, { desc = "[ai-chat] Send selection" })
    end
    if keys.focus_input then
        map("n", keys.focus_input, function()
            M.open()
            if state.ui.input_winid and vim.api.nvim_win_is_valid(state.ui.input_winid) then
                vim.api.nvim_set_current_win(state.ui.input_winid)
                vim.cmd("startinsert")
            end
        end, { desc = "[ai-chat] Focus input" })
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
    if state.ui.is_open and state.ui.chat_winid then
        require("ai-chat.ui.chat").update_winbar(
            state.ui.chat_winid,
            state.conversation
        )
    end
end

function M._uuid()
    local random = math.random
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and random(0, 0xf) or random(8, 0xb)
        return string.format("%x", v)
    end)
end

return M
