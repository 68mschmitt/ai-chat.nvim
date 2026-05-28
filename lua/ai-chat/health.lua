--- ai-chat.nvim — :checkhealth integration
--- Validates the runtime environment: neovim version, curl, provider
--- reachability, treesitter markdown parser, writable directories.

local M = {}

function M.check()
    vim.health.start("ai-chat.nvim")

    -- 1. Neovim version
    if vim.fn.has("nvim-0.10") == 1 then
        vim.health.ok("Neovim >= 0.10")
    else
        vim.health.error("Neovim >= 0.10 required", { "Upgrade neovim to 0.10 or later" })
    end

    -- 2. curl availability
    if vim.fn.executable("curl") == 1 then
        vim.health.ok("curl found")
    else
        vim.health.error("curl not found", {
            "Install curl — required for all provider communication",
        })
    end

    -- 3. Plugin initialization
    local ok_init, chat = pcall(require, "ai-chat")
    if not ok_init then
        vim.health.error("Failed to load ai-chat module", { tostring(chat) })
        return
    end

    local config
    local ok_config = pcall(function()
        config = chat.get_config()
    end)
    if not ok_config or not config or not config.default_provider then
        vim.health.warn("Plugin not initialized (setup() not called yet)", {
            "Add require('ai-chat').setup() to your config",
        })
        config = require("ai-chat.config").defaults
    else
        vim.health.ok("Plugin initialized")
    end

    -- 4. Default provider checks
    local provider_name = config.default_provider
    vim.health.info("Default provider: " .. provider_name)
    vim.health.info("Default model: " .. config.default_model)

    local providers = require("ai-chat.providers")
    for name, provider_config in pairs(config.providers or {}) do
        providers.health(name, provider_config, { is_default = name == provider_name })
    end

    -- 5. Treesitter markdown parser
    local ts_ok = pcall(vim.treesitter.language.inspect, "markdown")
    if ts_ok then
        vim.health.ok("Treesitter markdown parser installed")
    else
        vim.health.warn("Treesitter markdown parser not found", {
            "Install with :TSInstall markdown markdown_inline",
            "Code block syntax highlighting will be limited without it",
        })
    end

    -- 6. History directory writable
    local history_path = require("ai-chat.config").history_path(config)
    vim.fn.mkdir(history_path, "p")
    if vim.fn.isdirectory(history_path) == 1 then
        vim.health.ok("History directory: " .. history_path)
    else
        vim.health.warn("History directory not writable: " .. history_path)
    end

    -- 7. Log directory writable
    local log_path = require("ai-chat.config").log_path(config)
    local log_dir = vim.fn.fnamemodify(log_path, ":h")
    vim.fn.mkdir(log_dir, "p")
    if vim.fn.isdirectory(log_dir) == 1 then
        vim.health.ok("Log directory: " .. log_dir)
    else
        vim.health.warn("Log directory not writable: " .. log_dir)
    end
end

return M
