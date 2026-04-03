--- ai-chat.nvim — Interactive pickers and display helpers
--- User-facing interactive selection workflows (model picker, provider picker)
--- and information display functions (keybinding reference, config display).
--- Called by init.lua; does not require init.lua (no circular dependency).

local M = {}

local config = require("ai-chat.config")
local conversation = require("ai-chat.conversation")
local user_state = require("ai-chat.state")
local models = require("ai-chat.models")
local providers = require("ai-chat.providers")
local ui_util = require("ai-chat.util.ui")

--- Switch the active model.
--- When model_name is nil, opens an interactive picker.
---@param model_name? string
---@param update_winbar_fn fun()  Callback to refresh the winbar after changes
function M.set_model(model_name, update_winbar_fn)
    if model_name then
        conversation.set_model(model_name)
        user_state.set_last_model(conversation.get_provider(), model_name)
        update_winbar_fn()
        vim.notify("[ai-chat] Model: " .. model_name, vim.log.levels.INFO)
    else
        local provider_name = conversation.get_provider()
        local picker_items = models.get_picker_items(provider_name)

        if #picker_items > 0 then
            -- Rich picker with display names, context windows, and pricing
            local display_list = {}
            for _, item in ipairs(picker_items) do
                table.insert(display_list, item.display)
            end
            vim.ui.select(display_list, { prompt = "Select model:" }, function(_, idx)
                if idx then
                    M.set_model(picker_items[idx].id, update_winbar_fn)
                end
            end)
        else
            -- Fallback to provider's own list_models (e.g., Ollama local, OpenAI API)
            local provider = providers.get(provider_name)
            provider.list_models(config.get().providers[provider_name] or {}, function(models_list)
                if #models_list == 0 then
                    vim.notify("[ai-chat] No models available from " .. provider_name, vim.log.levels.WARN)
                    return
                end
                vim.ui.select(models_list, { prompt = "Select model:" }, function(choice)
                    if choice then
                        M.set_model(choice, update_winbar_fn)
                    end
                end)
            end)
        end
    end
end

--- Switch the active provider.
--- When provider_name is nil, opens an interactive picker.
---@param provider_name? string
---@param update_winbar_fn fun()  Callback to refresh the winbar after changes
function M.set_provider(provider_name, update_winbar_fn)
    if provider_name then
        if not providers.exists(provider_name) then
            vim.notify("[ai-chat] Unknown provider: " .. provider_name, vim.log.levels.WARN)
            return
        end
        conversation.set_provider(provider_name)
        local provider_config = config.get().providers[provider_name]
        if provider_config and provider_config.model then
            conversation.set_model(provider_config.model)
        end
        user_state.set_last_model(provider_name, conversation.get_model())
        update_winbar_fn()
        vim.notify("[ai-chat] Provider: " .. provider_name, vim.log.levels.INFO)
        pcall(vim.api.nvim_exec_autocmds, "User", {
            pattern = "AiChatProviderChanged",
            data = { provider = provider_name, model = conversation.get_model() },
        })
    else
        local available = providers.list()
        vim.ui.select(available, { prompt = "Select provider:" }, function(choice)
            if choice then
                M.set_provider(choice, update_winbar_fn)
            end
        end)
    end
end

--- Show keybinding reference.
---@param keys table  The keys config table
function M.show_keys(keys)
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
    ui_util.show_in_split(lines)
end

--- Show resolved configuration.
function M.show_config()
    local display_config = vim.deepcopy(config.get())
    for _, pname in ipairs({ "anthropic", "openai_compat" }) do
        if display_config.providers[pname] and display_config.providers[pname].api_key then
            display_config.providers[pname].api_key = "***"
        end
    end
    local lines = vim.split(vim.inspect(display_config), "\n")
    table.insert(lines, 1, "ai-chat.nvim Resolved Configuration")
    table.insert(lines, 2, string.rep("-", 40))
    ui_util.show_in_split(lines)
end

return M
