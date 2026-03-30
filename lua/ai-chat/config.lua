--- ai-chat.nvim — Configuration
--- Schema definition, defaults, validation, and resolution.
--- Owns the resolved config state. init.lua calls config.resolve() during
--- setup(). All other modules call config.get() to read the resolved config.

local M = {}

-- The resolved config after setup(). nil until resolve() is called.
---@type AiChatConfig?
local resolved = nil

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
            max_tokens = 16000,
            thinking_budget = 10000,
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
        show_thinking = true, -- render thinking blocks (false = strip entirely)
        auto_scroll = true,
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
        next_code_block = "]b",
        prev_code_block = "[b",
        yank_code_block = "gY",
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
        treesitter = true,
    },

    -- Logging
    log = {
        enabled = true,
        level = "info",
        file = nil,
        max_size_mb = 10,
    },
}

--- Deep merge user options with defaults and store the result.
--- Called once during setup(). Returns the resolved config.
---@param opts table  User-provided options
---@return AiChatConfig
function M.resolve(opts)
    resolved = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
    return resolved
end

--- Allowed keys for per-project config overrides.
--- Only these fields can be set from .ai-chat.lua — keybindings, UI, log,
--- and history are user preferences, not project properties.
local project_allowed_keys = {
    "system_prompt",
    "default_provider",
    "default_model",
}

--- Load and apply per-project config from .ai-chat.lua in the current
--- working directory. Called after resolve() during setup, and can be
--- re-called on /clear or project directory change.
---
--- The file must return a table. Only allowed keys and providers.* are applied.
--- Uses dofile() (not require) so edits are picked up without restart.
---@return boolean loaded  Whether a project config was found and applied
function M.load_project_config()
    if not resolved then
        return false
    end

    local project_file = vim.fn.getcwd() .. "/.ai-chat.lua"
    if vim.fn.filereadable(project_file) ~= 1 then
        return false
    end

    local ok, project = pcall(dofile, project_file)
    if not ok or type(project) ~= "table" then
        vim.notify("[ai-chat] Error loading .ai-chat.lua: " .. tostring(project), vim.log.levels.WARN)
        return false
    end

    -- Apply allowed top-level keys
    for _, key in ipairs(project_allowed_keys) do
        if project[key] ~= nil then
            if key == "system_prompt" then
                resolved.chat.system_prompt = project[key]
            else
                resolved[key] = project[key]
            end
        end
    end

    -- Deep merge chat.temperature if provided
    if project.temperature ~= nil then
        resolved.chat.temperature = project.temperature
    end

    -- Deep merge provider-specific config (project may configure a specific provider)
    if project.providers and type(project.providers) == "table" then
        for pname, pconfig in pairs(project.providers) do
            if type(pconfig) == "table" then
                resolved.providers[pname] = vim.tbl_deep_extend("force", resolved.providers[pname] or {}, pconfig)
            end
        end
    end

    vim.notify("[ai-chat] Loaded project config from .ai-chat.lua", vim.log.levels.INFO)
    return true
end

--- Get the currently resolved config.
--- Returns the resolved config after setup(), or defaults before setup().
---@return AiChatConfig
function M.get()
    return resolved or M.defaults
end

--- Update a config value at runtime (e.g., toggling thinking mode).
--- Only works after setup() has been called.
---@param path string  Dot-separated path (e.g., "chat.thinking")
---@param value any    New value
function M.set(path, value)
    if not resolved then
        return
    end
    local keys = vim.split(path, ".", { plain = true })
    local target = resolved
    for i = 1, #keys - 1 do
        target = target[keys[i]]
        if type(target) ~= "table" then
            return
        end
    end
    target[keys[#keys]] = value
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
    return config.history.storage_path or (vim.fn.stdpath("data") .. "/ai-chat/history")
end

--- Get the log file path, with default fallback.
---@param config? AiChatConfig
---@return string
function M.log_path(config)
    config = config or M.get()
    return config.log.file or (vim.fn.stdpath("data") .. "/ai-chat/log.txt")
end

return M
