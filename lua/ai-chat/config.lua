--- ai-chat.nvim — Configuration
--- Schema definition, defaults, validation, and resolution.
--- The resolved config is stored module-locally after setup() calls resolve().

local M = {}

---@type AiChatConfig?
local _resolved = nil

---@class AiChatConfig
M.defaults = {

    -- Active provider and model
    default_provider = "ollama",
    default_model = "llama3.2",

    -- Provider-specific configuration
    providers = {
        ollama = {
            host = "http://localhost:11434",
        },
        anthropic = {
            model = "claude-sonnet-4-20250514",
            max_tokens = 8192,
        },
        bedrock = {
            region = "us-east-1",
            model = "anthropic.claude-sonnet-4-20250514-v1:0",
        },
        openai_compat = {
            endpoint = "https://api.openai.com/v1/chat/completions",
            model = "gpt-4o",
        },
    },

    -- UI
    ui = {
        width = 0.25,
        min_width = 60,
        max_width = 120,
        position = "right",
        input_height = 3,
        input_max_height = 10,
        show_winbar = true,
        show_cost = true,
        show_tokens = true,
        spinner = true,
    },

    -- Chat behavior
    chat = {
        system_prompt = nil,
        temperature = 0.7,
        max_tokens = 4096,
        thinking = false,
        auto_scroll = true,
        show_context = true,
    },

    -- History / persistence
    history = {
        enabled = true,
        max_conversations = 100,
        storage_path = nil,
    },

    -- Keybindings (set any to false to disable)
    keys = {
        -- Global
        toggle = "<leader>aa",
        send_selection = "<leader>as",
        quick_explain = "<leader>ae",
        quick_fix = "<leader>af",
        focus_input = "<leader>ac",
        switch_model = "<leader>am",
        switch_provider = "<leader>ap",
        -- Chat buffer (buffer-local)
        close = "q",
        cancel = "<C-c>",
        next_message = "]]",
        prev_message = "[[",
        next_code_block = "]c",
        prev_code_block = "[c",
        yank_code_block = "gY",
        apply_code_block = "ga",
        open_code_block = "gO",
        show_help = "?",
        -- Input buffer (buffer-local)
        submit_normal = "<CR>",
        submit_insert = "<C-CR>",
        recall_prev = "<Up>",
        recall_next = "<Down>",
    },

    -- Optional integrations
    integrations = {
        telescope = true,
        treesitter = true,
        cmp = true,
    },

    -- Logging
    log = {
        enabled = true,
        level = "info",
        file = nil,
        max_size_mb = 10,
    },
}

--- Deep merge user options with defaults.
---@param opts table  User-provided options
---@return AiChatConfig
function M.resolve(opts)
    _resolved = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
    return _resolved
end

--- Get the currently resolved config. Returns defaults if setup hasn't run.
---@return AiChatConfig
function M.get()
    return _resolved or M.defaults
end

--- Validate a resolved config.
---@param config AiChatConfig
---@return boolean ok
---@return string? error_message
function M.validate(config)
    if type(config.default_provider) ~= "string" then
        return false, "default_provider must be a string"
    end
    if type(config.default_model) ~= "string" then
        return false, "default_model must be a string"
    end

    -- UI validation
    if type(config.ui.width) ~= "number" or config.ui.width <= 0 or config.ui.width >= 1 then
        return false, "ui.width must be a number between 0 and 1 (exclusive)"
    end
    if config.ui.position ~= "right" and config.ui.position ~= "left" then
        return false, "ui.position must be 'right' or 'left'"
    end

    -- Provider existence
    local valid_providers = { "ollama", "anthropic", "bedrock", "openai_compat" }
    local found = false
    for _, p in ipairs(valid_providers) do
        if p == config.default_provider then
            found = true
            break
        end
    end
    if not found then
        return false, "Unknown provider: " .. config.default_provider
    end

    -- Temperature range
    if config.chat.temperature < 0 or config.chat.temperature > 2 then
        return false, "chat.temperature must be between 0 and 2"
    end

    return true
end

--- Get the storage path for history, with default fallback.
---@param config? AiChatConfig
---@return string
function M.history_path(config)
    config = config or M.get()
    return config.history.storage_path
        or (vim.fn.stdpath("data") .. "/ai-chat/history")
end

--- Get the log file path, with default fallback.
---@param config? AiChatConfig
---@return string
function M.log_path(config)
    config = config or M.get()
    return config.log.file
        or (vim.fn.stdpath("data") .. "/ai-chat/log.txt")
end

return M
