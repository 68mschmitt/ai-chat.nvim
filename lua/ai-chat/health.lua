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
    local ok_config, err = pcall(function()
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

    -- Ollama reachability
    if provider_name == "ollama" then
        local host = (config.providers.ollama or {}).host or "http://localhost:11434"
        local result = vim.system(
            { "curl", "-s", "--connect-timeout", "3", host .. "/api/tags" },
            { text = true }
        ):wait()

        if result.code == 0 then
            local data_ok, data = pcall(vim.json.decode, result.stdout)
            if data_ok and data and data.models then
                local model_names = {}
                for _, m in ipairs(data.models) do
                    table.insert(model_names, m.name)
                end
                vim.health.ok("Ollama running at " .. host
                    .. " (" .. #data.models .. " models: "
                    .. table.concat(model_names, ", ") .. ")")
            else
                vim.health.ok("Ollama running at " .. host)
            end
        else
            vim.health.warn("Ollama not reachable at " .. host, {
                "Start Ollama with `ollama serve`",
                "Or switch provider: require('ai-chat').setup({ default_provider = 'anthropic' })",
            })
        end
    end

    -- Anthropic API key
    if provider_name == "anthropic" or config.providers.anthropic then
        local api_key = (config.providers.anthropic or {}).api_key or vim.env.ANTHROPIC_API_KEY
        if api_key and api_key ~= "" then
            vim.health.ok("Anthropic API key found")
        else
            local level = provider_name == "anthropic" and "error" or "info"
            vim.health[level](
                "Anthropic API key not set",
                { "Set ANTHROPIC_API_KEY environment variable" }
            )
        end
    end

    -- OpenAI API key
    if provider_name == "openai_compat" or config.providers.openai_compat then
        local api_key = (config.providers.openai_compat or {}).api_key or vim.env.OPENAI_API_KEY
        if api_key and api_key ~= "" then
            vim.health.ok("OpenAI API key found")
        else
            local level = provider_name == "openai_compat" and "error" or "info"
            vim.health[level](
                "OpenAI API key not set",
                { "Set OPENAI_API_KEY environment variable" }
            )
        end
    end

    -- Bedrock (aws CLI)
    if provider_name == "bedrock" or config.providers.bedrock then
        if vim.fn.executable("aws") == 1 then
            vim.health.ok("AWS CLI found (for Bedrock)")
        else
            local level = provider_name == "bedrock" and "error" or "info"
            vim.health[level](
                "AWS CLI not found",
                { "Install AWS CLI for Bedrock support" }
            )
        end
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
