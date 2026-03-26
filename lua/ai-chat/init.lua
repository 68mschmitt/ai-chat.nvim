--- ai-chat.nvim — Main module
--- Public API and module coordinator.
--- All user-facing functions live here. Internal modules are accessed
--- through this coordinator, never directly by the user.
---
--- State ownership:
---   config       → owned by config.lua (resolved state lives there)
---   conversation → owned by conversation.lua
---   streaming    → owned by stream.lua
---   ui refs      → owned here (chat_bufnr, chat_winid, etc.)

local M = {}

---@class AiChatState
local state = {
    ui = {
        chat_bufnr = nil,
        chat_winid = nil,
        input_bufnr = nil,
        input_winid = nil,
        is_open = false,
    },
    last_code_bufnr = nil,
}

local initialized = false

-- Lazy module references (populated on first use)
local conversation -- ai-chat.conversation
local stream -- ai-chat.stream
local pipeline -- ai-chat.pipeline

local function get_conversation()
    if not conversation then
        conversation = require("ai-chat.conversation")
    end
    return conversation
end

local function get_stream()
    if not stream then
        stream = require("ai-chat.stream")
    end
    return stream
end

local function get_pipeline()
    if not pipeline then
        pipeline = require("ai-chat.pipeline")
    end
    return pipeline
end

-- ─── Setup ───────────────────────────────────────────────────────────

--- Initialize the plugin. Must be called once in the user's config.
---@param opts? table  User configuration (merged with defaults)
function M.setup(opts)
    local config = require("ai-chat.config")
    local resolved = config.resolve(opts or {})

    local ok, err = config.validate(resolved)
    if not ok then
        vim.notify("[ai-chat] Configuration error: " .. err, vim.log.levels.ERROR)
        return
    end

    require("ai-chat.highlights").setup()
    math.randomseed(os.time() + (vim.uv or vim.loop).hrtime())
    require("ai-chat.keymaps").setup(resolved.keys)

    -- Load per-project config (.ai-chat.lua in cwd) — applies allowed overrides
    config.load_project_config()

    if resolved.history.enabled then
        require("ai-chat.history").init(resolved.history)
    end

    require("ai-chat.util.log").init(resolved.log)

    -- Initialize model registry (loads from disk cache, kicks off async refresh)
    require("ai-chat.models").init()
    M._setup_code_buffer_tracking()
    get_conversation().new(resolved.default_provider, resolved.default_model)

    initialized = true
end

-- ─── Panel ───────────────────────────────────────────────────────────

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
    if state.ui.is_open then
        return
    end

    local config = require("ai-chat.config").get()
    local result = require("ai-chat.ui").open(config.ui, get_conversation().get())
    state.ui.chat_bufnr = result.chat_bufnr
    state.ui.chat_winid = result.chat_winid
    state.ui.input_bufnr = result.input_bufnr
    state.ui.input_winid = result.input_winid
    state.ui.is_open = true

    require("ai-chat.lifecycle").setup(state.ui, get_stream)

    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AiChatPanelOpened",
        data = { winid = state.ui.chat_winid, bufnr = state.ui.chat_bufnr },
    })
end

--- Close the chat panel.
function M.close()
    if not state.ui.is_open then
        return
    end
    if get_stream().is_active() then
        M.cancel()
    end
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

-- ─── Messaging ───────────────────────────────────────────────────────

--- Send a message to the AI. Delegates orchestration to pipeline.lua.
---@param text? string  Message text. If nil, uses current input buffer content.
---@param opts? { context?: string[], callback?: fun(response: AiChatResponse) }
function M.send(text, opts)
    M._ensure_init()
    opts = opts or {}
    local config = require("ai-chat.config").get()

    if not text then
        text = require("ai-chat.ui.input").get_text()
    end
    if not text or text == "" then
        return
    end

    get_pipeline().send(text, opts, state.ui, {
        conversation = get_conversation(),
        stream = get_stream(),
        config = config,
        open_fn = function()
            M.open()
        end,
        update_winbar_fn = function()
            M._update_winbar()
        end,
    })
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

-- ─── Conversation ────────────────────────────────────────────────────

--- Clear the current conversation and start fresh.
function M.clear()
    M._ensure_init()
    local config = require("ai-chat.config").get()
    if get_stream().is_active() then
        M.cancel()
    end
    get_conversation().new(config.default_provider, config.default_model)
    get_pipeline().reset()
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

--- Get the resolved configuration (read-only copy).
---@return AiChatConfig
function M.get_config()
    return vim.deepcopy(require("ai-chat.config").get())
end

--- Get the last known code buffer number.
---@return number?
function M.get_last_code_bufnr()
    if state.last_code_bufnr and vim.api.nvim_buf_is_valid(state.last_code_bufnr) then
        return state.last_code_bufnr
    end
    return nil
end

-- ─── Model / Provider ────────────────────────────────────────────────

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
        local config = require("ai-chat.config").get()
        local provider_name = conv.get_provider()
        local registry = require("ai-chat.models")
        local picker_items = registry.get_picker_items(provider_name)

        if #picker_items > 0 then
            -- Rich picker with display names, context windows, and pricing
            local display_list = {}
            for _, item in ipairs(picker_items) do
                table.insert(display_list, item.display)
            end
            vim.ui.select(display_list, { prompt = "Select model:" }, function(_, idx)
                if idx then
                    M.set_model(picker_items[idx].id)
                end
            end)
        else
            -- Fallback to provider's own list_models (e.g., Ollama local, OpenAI API)
            local provider = require("ai-chat.providers").get(provider_name)
            provider.list_models(config.providers[provider_name] or {}, function(models)
                if #models == 0 then
                    vim.notify("[ai-chat] No models available from " .. provider_name, vim.log.levels.WARN)
                    return
                end
                vim.ui.select(models, { prompt = "Select model:" }, function(choice)
                    if choice then
                        M.set_model(choice)
                    end
                end)
            end)
        end
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
        local config = require("ai-chat.config").get()
        local provider_config = config.providers[provider_name]
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
    require("ai-chat.config").set("chat.thinking", enabled)
    vim.notify("[ai-chat] Thinking mode: " .. (enabled and "ON" or "OFF"), vim.log.levels.INFO)
    M._update_winbar()
end

-- ─── History ─────────────────────────────────────────────────────────

--- Save the current conversation.
---@param name? string  Optional name for the conversation.
function M.save(name)
    M._ensure_init()
    if require("ai-chat.config").get().history.enabled then
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
                require("ai-chat.ui.render").render_conversation(state.ui.chat_bufnr, get_conversation().get())
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

-- ─── Display ─────────────────────────────────────────────────────────

--- Show keybinding reference.
function M.show_keys()
    local keys = initialized and require("ai-chat.config").get().keys or require("ai-chat.config").defaults.keys
    local lines = { "ai-chat.nvim Keybindings", string.rep("-", 40) }
    local sections = {
        {
            "Global",
            {
                { "toggle", "Toggle chat panel" },
                { "send_selection", "Send selection to chat" },
                { "quick_explain", "Explain selection" },
                { "quick_fix", "Fix selection" },
                { "focus_input", "Focus chat input" },
                { "switch_model", "Switch model" },
                { "switch_provider", "Switch provider" },
            },
        },
        {
            "Chat Buffer",
            {
                { "close", "Close panel" },
                { "cancel", "Cancel generation" },
                { "next_message", "Next message" },
                { "prev_message", "Previous message" },
                { "next_code_block", "Next code block" },
                { "prev_code_block", "Previous code block" },
                { "yank_code_block", "Yank code block" },
                { "apply_code_block", "Apply code block (diff)" },
                { "open_code_block", "Open code block in split" },
            },
        },
        {
            "Input",
            {
                { "submit_normal", "Send message (normal)" },
                { "submit_insert", "Send message (insert)" },
                { "recall_prev", "Previous in history" },
                { "recall_next", "Next in history" },
            },
        },
    }
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
    local display_config = vim.deepcopy(require("ai-chat.config").get())
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

--- Track the last code buffer the user was editing.
function M._setup_code_buffer_tracking()
    vim.api.nvim_create_autocmd("BufEnter", {
        group = vim.api.nvim_create_augroup("ai-chat-code-buffer", { clear = true }),
        callback = function(args)
            local bufnr = args.buf
            if vim.bo[bufnr].buftype ~= "" then
                return
            end
            if vim.api.nvim_buf_get_name(bufnr) == "" then
                return
            end
            state.last_code_bufnr = bufnr
        end,
    })
end

function M._update_winbar()
    if state.ui.is_open and state.ui.chat_winid and vim.api.nvim_win_is_valid(state.ui.chat_winid) then
        require("ai-chat.ui.chat").update_winbar(state.ui.chat_winid, get_conversation().get())
    end
end

return M
