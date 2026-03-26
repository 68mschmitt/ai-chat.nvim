-- ai-chat.nvim entry point
-- This file is loaded by neovim's plugin loader. It should be minimal:
-- register commands and autocommands, nothing else.
-- All heavy logic lives in lua/ai-chat/*.lua and is lazy-loaded.

if vim.g.loaded_ai_chat then
    return
end
vim.g.loaded_ai_chat = true

-- Require neovim 0.10+ for vim.system() and modern extmark features
if vim.fn.has("nvim-0.10") ~= 1 then
    vim.notify("[ai-chat] Requires Neovim 0.10 or later", vim.log.levels.ERROR)
    return
end

-- Commands (lazy-load the module on first use)
vim.api.nvim_create_user_command("AiChat", function()
    require("ai-chat").toggle()
end, { desc = "Toggle AI chat panel" })

vim.api.nvim_create_user_command("AiChatOpen", function()
    require("ai-chat").open()
end, { desc = "Open AI chat panel" })

vim.api.nvim_create_user_command("AiChatClose", function()
    require("ai-chat").close()
end, { desc = "Close AI chat panel" })

vim.api.nvim_create_user_command("AiChatSend", function(opts)
    require("ai-chat").send(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Send message to AI chat" })

vim.api.nvim_create_user_command("AiChatClear", function()
    require("ai-chat").clear()
end, { desc = "Clear AI chat conversation" })

vim.api.nvim_create_user_command("AiChatModel", function(opts)
    require("ai-chat").set_model(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Switch AI chat model" })

vim.api.nvim_create_user_command("AiChatProvider", function(opts)
    require("ai-chat").set_provider(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Switch AI chat provider" })

vim.api.nvim_create_user_command("AiChatHistory", function()
    require("ai-chat").history()
end, { desc = "Browse AI chat history" })

vim.api.nvim_create_user_command("AiChatSave", function(opts)
    require("ai-chat").save(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "Save AI chat conversation" })

vim.api.nvim_create_user_command("AiChatLog", function()
    require("ai-chat.util.log").open()
end, { desc = "Open AI chat audit log" })

vim.api.nvim_create_user_command("AiChatCosts", function()
    require("ai-chat.util.costs").show()
end, { desc = "Show AI chat cost summary" })

vim.api.nvim_create_user_command("AiChatKeys", function()
    require("ai-chat").show_keys()
end, { desc = "Show AI chat keybindings" })

vim.api.nvim_create_user_command("AiChatConfig", function()
    require("ai-chat").show_config()
end, { desc = "Show AI chat resolved configuration" })
