--- ai-chat.nvim — Highlight group definitions
--- Defines all highlight groups used by the plugin.
--- Each group uses `default = true` so users can override in their colorscheme.

local M = {}

--- Set up all highlight groups.
--- Called once during setup(). Safe to call multiple times (idempotent).
function M.setup()
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
    hl(0, "AiChatProposalSign", { default = true, link = "DiffAdd" })
    hl(0, "AiChatProposalExpired", { default = true, link = "WarningMsg" })
end

return M
