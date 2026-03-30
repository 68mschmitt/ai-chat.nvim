--- ai-chat.nvim — Global keymap registration
--- Sets up global (non-buffer-local) keybindings during setup().
--- Buffer-local keymaps for chat/input buffers live in their respective
--- UI modules (ui/chat.lua, ui/input.lua).

local M = {}

--- Register global keymaps based on user config.
--- Called once during setup(). Each key can be set to `false` to disable.
---@param keys table  The keys section of AiChatConfig
function M.setup(keys)
    local map = vim.keymap.set

    if keys.toggle then
        map("n", keys.toggle, function()
            require("ai-chat").toggle()
        end, { desc = "[ai-chat] Toggle panel" })
    end

    if keys.send_selection then
        map("v", keys.send_selection, function()
            vim.cmd('normal! "zy')
            local sel = vim.fn.getreg("z")
            if sel and sel ~= "" then
                require("ai-chat").open()
                require("ai-chat").send(sel)
            end
        end, { desc = "[ai-chat] Send selection" })
    end

    if keys.quick_explain then
        map("v", keys.quick_explain, function()
            vim.cmd('normal! "zy')
            local sel = vim.fn.getreg("z")
            if sel and sel ~= "" then
                require("ai-chat").open()
                require("ai-chat").send("Explain this code:\n\n" .. sel)
            end
        end, { desc = "[ai-chat] Explain selection" })
    end

    if keys.quick_fix then
        map("v", keys.quick_fix, function()
            vim.cmd('normal! "zy')
            local sel = vim.fn.getreg("z")
            if sel and sel ~= "" then
                require("ai-chat").open()
                require("ai-chat").send("Fix this code:\n\n" .. sel)
            end
        end, { desc = "[ai-chat] Fix selection" })
    end

    if keys.focus_input then
        map("n", keys.focus_input, function()
            require("ai-chat").open()
            require("ai-chat.ui.input").focus()
        end, { desc = "[ai-chat] Focus input" })
    end

    if keys.switch_model then
        map("n", keys.switch_model, function()
            require("ai-chat").set_model()
        end, { desc = "[ai-chat] Switch model" })
    end

    if keys.switch_provider then
        map("n", keys.switch_provider, function()
            require("ai-chat").set_provider()
        end, { desc = "[ai-chat] Switch provider" })
    end

end

return M
