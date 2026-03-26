--- ai-chat.nvim — Main module
--- Public API and module coordinator.
--- All user-facing functions live here. Internal modules are accessed
--- through this coordinator, never directly by the user.
---
--- State ownership:
---   config       → owned here
---   conversation → owned by conversation.lua
---   streaming    → owned by stream.lua
---   ui refs      → owned here (chat_bufnr, chat_winid, etc.)

local M = {}

---@class AiChatState
local state = {
    config = {},
    ui = {
        chat_bufnr = nil,
        chat_winid = nil,
        input_bufnr = nil,
        input_winid = nil,
        is_open = false,
    },
    _ollama_checked = false,
}

local initialized = false

-- Lazy module references (populated on first use)
local conversation -- ai-chat.conversation
local stream       -- ai-chat.stream

local function get_conversation()
    if not conversation then conversation = require("ai-chat.conversation") end
    return conversation
end

local function get_stream()
    if not stream then stream = require("ai-chat.stream") end
    return stream
end

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

    -- Seed random number generator once (used for conversation UUIDs)
    math.randomseed(os.time() + (vim.uv or vim.loop).hrtime())

    -- Set up global keybindings
    M._setup_keymaps()

    -- Initialize history if enabled
    if state.config.history.enabled then
        require("ai-chat.history").init(state.config.history)
    end

    -- Initialize logging
    require("ai-chat.util.log").init(state.config.log)

    -- Start a new conversation
    get_conversation().new(state.config.default_provider, state.config.default_model)

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
    local conv = get_conversation().get()
    local result = ui.open(state.config.ui, conv)
    state.ui.chat_bufnr = result.chat_bufnr
    state.ui.chat_winid = result.chat_winid
    state.ui.input_bufnr = result.input_bufnr
    state.ui.input_winid = result.input_winid
    state.ui.is_open = true

    -- Set up buffer lifecycle guards
    M._setup_lifecycle_autocmds()

    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AiChatPanelOpened",
        data = { winid = state.ui.chat_winid, bufnr = state.ui.chat_bufnr },
    })
end

--- Close the chat panel.
function M.close()
    if not state.ui.is_open then return end

    -- Cancel any active generation
    if get_stream().is_active() then
        M.cancel()
    end

    -- Clean up lifecycle autocmds
    pcall(vim.api.nvim_del_augroup_by_name, "ai-chat-lifecycle")

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
        require("ai-chat.commands").handle(text, {
            config = state.config,
            conversation = get_conversation().get(),
        })
        -- Clear the input after handling slash command
        if state.ui.is_open then
            require("ai-chat.ui.input").clear()
        end
        return
    end

    -- Don't send while already streaming
    if get_stream().is_active() then
        vim.notify("[ai-chat] Already generating a response. Press <C-c> to cancel.", vim.log.levels.WARN)
        return
    end

    -- First-run Ollama detection
    if not state._ollama_checked and get_conversation().get_provider() == "ollama" then
        state._ollama_checked = true
        M._check_ollama()
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
    local conv = get_conversation()
    conv.append(message)

    -- Render user message in chat
    require("ai-chat.ui.render").render_message(state.ui.chat_bufnr, message)

    -- Clear input
    require("ai-chat.ui.input").clear()

    -- Build provider messages (system prompt + history + context + truncation)
    local provider_messages, truncated = conv.build_provider_messages(state.config)

    -- Notify user if truncation happened (one-time per conversation)
    if truncated and not state._truncation_notified then
        state._truncation_notified = true
        vim.notify(
            string.format("[ai-chat] Context window: %d older messages truncated", truncated),
            vim.log.levels.INFO
        )
    end

    -- Start streaming
    local provider = require("ai-chat.providers").get(conv.get_provider())

    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AiChatResponseStart",
        data = { provider = conv.get_provider(), model = conv.get_model() },
    })

    -- Final guard: ensure panel is still open before starting the stream
    if not state.ui.is_open or not state.ui.chat_bufnr then return end

    get_stream().send(
        provider,
        provider_messages,
        {
            model = conv.get_model(),
            provider_name = conv.get_provider(),
            temperature = state.config.chat.temperature,
            max_tokens = state.config.chat.max_tokens,
            thinking = state.config.chat.thinking,
        },
        {
            chat_bufnr = state.ui.chat_bufnr,
            chat_winid = state.ui.chat_winid,
        },
        {
            on_done = function(response)
                -- Update winbar with new message count
                M._update_winbar()

                -- Store assistant message
                conv.append({
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
                        conv.get_provider(),
                        conv.get_model(),
                        response.usage
                    )
                end

                -- Auto-save conversation
                if state.config.history.enabled then
                    require("ai-chat.history").save(conv.get())
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
    get_stream().cancel()
end

--- Returns whether a response is currently being streamed.
---@return boolean
function M.is_streaming()
    return get_stream().is_active()
end

--- Clear the current conversation and start fresh.
function M.clear()
    M._ensure_init()
    if get_stream().is_active() then
        M.cancel()
    end
    get_conversation().new(state.config.default_provider, state.config.default_model)
    state._truncation_notified = nil
    if state.ui.is_open then
        require("ai-chat.ui.render").clear(state.ui.chat_bufnr)
        M._update_winbar()
    end
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatConversationCleared" })
end

--- Get a read-only copy of the current conversation.
---@return AiChatConversation
function M.get_conversation()
    return get_conversation().get()
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
    local conv = get_conversation()
    if model_name then
        conv.set_model(model_name)
        M._update_winbar()
        vim.notify("[ai-chat] Model: " .. model_name, vim.log.levels.INFO)
    else
        local provider = require("ai-chat.providers").get(conv.get_provider())
        provider.list_models(
            state.config.providers[conv.get_provider()] or {},
            function(models)
                if #models == 0 then
                    vim.notify("[ai-chat] No models available from " .. conv.get_provider(), vim.log.levels.WARN)
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
    local conv = get_conversation()
    if provider_name then
        local providers = require("ai-chat.providers")
        if not providers.exists(provider_name) then
            vim.notify("[ai-chat] Unknown provider: " .. provider_name, vim.log.levels.WARN)
            return
        end
        conv.set_provider(provider_name)
        local provider_config = state.config.providers[provider_name]
        if provider_config and provider_config.model then
            conv.set_model(provider_config.model)
        end
        M._update_winbar()
        vim.notify("[ai-chat] Provider: " .. provider_name, vim.log.levels.INFO)
        pcall(vim.api.nvim_exec_autocmds, "User", {
            pattern = "AiChatProviderChanged",
            data = { provider = provider_name, model = conv.get_model() },
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

--- Set thinking mode on or off.
---@param enabled boolean
function M.set_thinking(enabled)
    M._ensure_init()
    state.config.chat.thinking = enabled
    local status = enabled and "ON" or "OFF"
    vim.notify("[ai-chat] Thinking mode: " .. status, vim.log.levels.INFO)
    M._update_winbar()
end

--- Save the current conversation.
---@param name? string  Optional name for the conversation.
function M.save(name)
    M._ensure_init()
    if state.config.history.enabled then
        require("ai-chat.history").save(get_conversation().get(), name)
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
            get_conversation().restore(conv)
            if state.ui.is_open then
                require("ai-chat.ui.render").render_conversation(
                    state.ui.chat_bufnr, get_conversation().get()
                )
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

    require("ai-chat.util.ui").show_in_split(lines)
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

    require("ai-chat.util.ui").show_in_split(lines)
end

-- ─── Internal ────────────────────────────────────────────────────────

function M._ensure_init()
    if not initialized then
        error("[ai-chat] Plugin not initialized. Call require('ai-chat').setup() first.")
    end
end

--- Internal config accessor for config.lua to delegate to.
--- Avoids a second copy of the resolved config.
function M._get_config()
    return state.config
end

--- Set up buffer lifecycle autocommands to guard against inconsistent state.
--- Registered in a single augroup cleared on each open() and deleted on close().
function M._setup_lifecycle_autocmds()
    local group = vim.api.nvim_create_augroup("ai-chat-lifecycle", { clear = true })

    -- Guard: chat window closed externally (`:q`, `<C-w>c`, `:only`)
    if state.ui.chat_winid then
        vim.api.nvim_create_autocmd("WinClosed", {
            group = group,
            pattern = tostring(state.ui.chat_winid),
            callback = function()
                vim.schedule(function()
                    if not state.ui.is_open then return end
                    -- Cancel stream, stop spinner
                    if get_stream().is_active() then
                        get_stream().cancel()
                    end
                    -- Destroy input (it lives inside the chat split)
                    pcall(require("ai-chat.ui.input").destroy)
                    -- Nil out state
                    state.ui.is_open = false
                    state.ui.chat_winid = nil
                    state.ui.input_winid = nil
                    state.ui.chat_bufnr = nil
                    state.ui.input_bufnr = nil
                    pcall(vim.api.nvim_del_augroup_by_name, "ai-chat-lifecycle")
                    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatPanelClosed" })
                end)
            end,
        })
    end

    -- Guard: chat buffer wiped (`:bwipeout`)
    if state.ui.chat_bufnr then
        vim.api.nvim_create_autocmd("BufWipeout", {
            group = group,
            buffer = state.ui.chat_bufnr,
            callback = function()
                vim.schedule(function()
                    if not state.ui.is_open then return end
                    if get_stream().is_active() then
                        get_stream().cancel()
                    end
                    pcall(require("ai-chat.ui.input").destroy)
                    -- Don't try to close the window — buffer is already gone
                    state.ui.is_open = false
                    state.ui.chat_winid = nil
                    state.ui.input_winid = nil
                    state.ui.chat_bufnr = nil
                    state.ui.input_bufnr = nil
                    pcall(vim.api.nvim_del_augroup_by_name, "ai-chat-lifecycle")
                    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatPanelClosed" })
                end)
            end,
        })
    end

    -- Guard: input buffer wiped externally
    if state.ui.input_bufnr then
        vim.api.nvim_create_autocmd("BufWipeout", {
            group = group,
            buffer = state.ui.input_bufnr,
            callback = function()
                vim.schedule(function()
                    if not state.ui.is_open then return end
                    -- If chat window is still valid, recreate the input
                    if state.ui.chat_winid and vim.api.nvim_win_is_valid(state.ui.chat_winid) then
                        local input = require("ai-chat.ui.input")
                        local result = input.create(state.ui.chat_winid, state.config.ui.input_height)
                        state.ui.input_bufnr = result.bufnr
                        state.ui.input_winid = result.winid
                    else
                        -- Chat window also gone — full close
                        state.ui.is_open = false
                        state.ui.chat_winid = nil
                        state.ui.input_winid = nil
                        state.ui.chat_bufnr = nil
                        state.ui.input_bufnr = nil
                        pcall(vim.api.nvim_del_augroup_by_name, "ai-chat-lifecycle")
                        pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatPanelClosed" })
                    end
                end)
            end,
        })
    end
end

function M._setup_keymaps()
    local keys = state.config.keys
    local map = vim.keymap.set

    if keys.toggle then
        map("n", keys.toggle, function() M.toggle() end, { desc = "[ai-chat] Toggle panel" })
    end

    if keys.send_selection then
        map("v", keys.send_selection, function()
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
    hl(0, "AiChatThinking", { default = true, link = "Comment" })
    hl(0, "AiChatThinkingHeader", { default = true, link = "DiagnosticInfo" })
end

function M._update_winbar()
    if state.ui.is_open and state.ui.chat_winid
        and vim.api.nvim_win_is_valid(state.ui.chat_winid) then
        require("ai-chat.ui.chat").update_winbar(
            state.ui.chat_winid,
            get_conversation().get()
        )
    end
end

--- Async check if Ollama is running. Called once per session on first send.
function M._check_ollama()
    local host = (state.config.providers.ollama or {}).host or "http://localhost:11434"
    vim.system(
        { "curl", "-s", "--connect-timeout", "2", host .. "/api/tags" },
        {},
        function(result)
            if result.code ~= 0 then
                vim.schedule(function()
                    vim.notify(
                        "[ai-chat] Ollama not detected at " .. host
                        .. ". Start it with `ollama serve` or switch provider with /provider.",
                        vim.log.levels.WARN
                    )
                end)
            end
        end
    )
end

return M
