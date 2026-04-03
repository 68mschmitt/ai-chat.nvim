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

local config = require("ai-chat.config")
local conversation = require("ai-chat.conversation")
local stream = require("ai-chat.stream")
local pipeline = require("ai-chat.pipeline")
local providers = require("ai-chat.providers")
local models = require("ai-chat.models")
local user_state = require("ai-chat.state")
local history = require("ai-chat.history")
local log = require("ai-chat.util.log")
local highlights = require("ai-chat.highlights")
local keymaps_mod = require("ai-chat.keymaps")
local ui = require("ai-chat.ui")
local ui_render = require("ai-chat.ui.render")
local ui_input = require("ai-chat.ui.input")
local ui_chat = require("ai-chat.ui.chat")
local lifecycle = require("ai-chat.lifecycle")
local pickers = require("ai-chat.pickers")

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

-- ─── Setup ───────────────────────────────────────────────────────────

--- Initialize the plugin. Must be called once in the user's config.
---@param opts? table  User configuration (merged with defaults)
function M.setup(opts)
    local resolved = config.resolve(opts or {})

    local ok, err = config.validate(resolved)
    if not ok then
        vim.notify("[ai-chat] Configuration error: " .. err, vim.log.levels.ERROR)
        return
    end

    highlights.setup()
    math.randomseed(os.time() + (vim.uv or vim.loop).hrtime())
    keymaps_mod.setup(resolved.keys)

    -- Load per-project config (.ai-chat.lua in cwd) — applies allowed overrides
    config.load_project_config()

    if resolved.history.enabled then
        history.init(resolved.history)
    end

    log.init(resolved.log)

    -- Initialize model registry (loads from disk cache, kicks off async refresh)
    models.init()
    M._setup_code_buffer_tracking()

    -- Restore last used provider/model if available, otherwise use config defaults
    user_state.load()
    local init_provider = user_state.get_last_provider() or resolved.default_provider
    local init_model = user_state.get_last_model() or resolved.default_model

    -- Validate the persisted provider is still valid
    if not providers.exists(init_provider) then
        init_provider = resolved.default_provider
        init_model = resolved.default_model
    end

    conversation.new(init_provider, init_model)

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

    local result = ui.open(config.get().ui, conversation.get())
    state.ui.chat_bufnr = result.chat_bufnr
    state.ui.chat_winid = result.chat_winid
    state.ui.input_bufnr = result.input_bufnr
    state.ui.input_winid = result.input_winid
    state.ui.is_open = true

    lifecycle.setup(state.ui, function()
        return stream
    end)

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
    if stream.is_active() then
        M.cancel()
    end
    pcall(vim.api.nvim_del_augroup_by_name, "ai-chat-lifecycle")
    ui.close()
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
function M.send(text)
    M._ensure_init()

    if not text then
        text = ui_input.get_text()
    end
    if not text or text == "" then
        return
    end

    pipeline.send(text, state.ui, {
        conversation = conversation,
        stream = stream,
        config = config.get(),
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
    stream.cancel()
end

--- Returns whether a response is currently being streamed.
---@return boolean
function M.is_streaming()
    return stream.is_active()
end

-- ─── Conversation ────────────────────────────────────────────────────

--- Clear the current conversation and start fresh.
function M.clear()
    M._ensure_init()
    if stream.is_active() then
        M.cancel()
    end
    -- Preserve the user's last provider/model choice across clears
    local provider = user_state.get_last_provider() or config.get().default_provider
    local model = user_state.get_last_model() or config.get().default_model
    conversation.new(provider, model)
    pipeline.reset()
    if state.ui.is_open then
        ui_render.clear(state.ui.chat_bufnr)
        M._update_winbar()
    end
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatConversationCleared" })
end

--- Get a read-only copy of the current conversation.
---@return AiChatConversation
function M.get_conversation()
    return conversation.get()
end

--- Get the resolved configuration (read-only copy).
---@return AiChatConfig
function M.get_config()
    return vim.deepcopy(config.get())
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
    pickers.set_model(model_name, function()
        M._update_winbar()
    end)
end

--- Switch the active provider.
---@param provider_name? string  If nil, opens a picker.
function M.set_provider(provider_name)
    M._ensure_init()
    pickers.set_provider(provider_name, function()
        M._update_winbar()
    end)
end

--- Set thinking mode on or off.
---@param enabled boolean
function M.set_thinking(enabled)
    M._ensure_init()
    config.set("chat.thinking", enabled)
    vim.notify("[ai-chat] Thinking mode: " .. (enabled and "ON" or "OFF"), vim.log.levels.INFO)
    M._update_winbar()
end

-- ─── History ─────────────────────────────────────────────────────────

--- Save the current conversation.
---@param name? string  Optional name for the conversation.
function M.save(name)
    M._ensure_init()
    if config.get().history.enabled then
        history.save(conversation.get(), name)
        vim.notify("[ai-chat] Conversation saved", vim.log.levels.INFO)
    end
end

--- Load a conversation by ID.
---@param id? string  If nil, opens a history browser.
function M.load(id)
    M._ensure_init()
    if id then
        local conv = history.load(id)
        if conv then
            conversation.restore(conv)
            if state.ui.is_open then
                ui_render.render_conversation(state.ui.chat_bufnr, conversation.get())
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
    history.browse(function(conv)
        if conv then
            M.load(conv.id)
        end
    end)
end

-- ─── Display ─────────────────────────────────────────────────────────

--- Show keybinding reference.
function M.show_keys()
    local keys = initialized and config.get().keys or config.defaults.keys
    pickers.show_keys(keys)
end

--- Show resolved configuration.
function M.show_config()
    M._ensure_init()
    pickers.show_config()
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
        ui_chat.update_winbar(state.ui.chat_winid, conversation.get())
    end
end

return M
