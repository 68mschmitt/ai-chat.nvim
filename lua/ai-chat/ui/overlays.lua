--- ai-chat.nvim --- Shared overlay utilities
--- Thin wrappers around nvim_buf_set_extmark for sign placement, virtual
--- text, and namespace management. Used by ui/proposals.lua (v0.4) and
--- ui/annotations.lua (v0.5).
---
--- Pure vim.api calls. No coordinator requires. No plugin-internal state.

local M = {}

--- Namespace for proposal overlays.
M.ns_proposals = vim.api.nvim_create_namespace("ai-chat-proposals")

--- Namespace for annotation overlays (reserved for v0.5).
M.ns_annotations = vim.api.nvim_create_namespace("ai-chat-annotations")

--- Place a sign with optional right-aligned virtual text.
---@param bufnr number
---@param line number 1-indexed line number
---@param ns number Namespace ID
---@param opts { sign_text: string, sign_hl: string, virt_text?: string, virt_hl?: string }
---@return number extmark_id
function M.place_sign(bufnr, line, ns, opts)
    local extmark_opts = {
        sign_text = opts.sign_text,
        sign_hl_group = opts.sign_hl,
    }
    if opts.virt_text then
        extmark_opts.virt_text = { { opts.virt_text, opts.virt_hl or "Comment" } }
        extmark_opts.virt_text_pos = "right_align"
    end
    -- nvim_buf_set_extmark uses 0-indexed lines
    return vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, extmark_opts)
end

--- Update an existing extmark (e.g., for expiry dimming or virt_lines toggle).
---@param bufnr number
---@param extmark_id number
---@param ns number Namespace ID
---@param opts { sign_text?: string, sign_hl?: string, virt_text?: string, virt_hl?: string, virt_lines?: table[][]|false }
function M.update_sign(bufnr, extmark_id, ns, opts)
    -- Get current position to preserve it
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, extmark_id, {})
    if not mark or #mark == 0 then
        return
    end

    local update_opts = {}
    if opts.sign_text then
        update_opts.sign_text = opts.sign_text
    end
    if opts.sign_hl then
        update_opts.sign_hl_group = opts.sign_hl
    end
    if opts.virt_text then
        update_opts.virt_text = { { opts.virt_text, opts.virt_hl or "Comment" } }
        update_opts.virt_text_pos = "right_align"
    end
    -- virt_lines: pass pre-formatted lines, or false/empty to clear
    if opts.virt_lines == false then
        update_opts.virt_lines = {}
    elseif opts.virt_lines then
        update_opts.virt_lines = opts.virt_lines
    end

    vim.api.nvim_buf_set_extmark(bufnr, ns, mark[1], mark[2], vim.tbl_extend("force", { id = extmark_id }, update_opts))
end

--- Remove a single extmark.
---@param bufnr number
---@param extmark_id number
---@param ns number Namespace ID
function M.remove_sign(bufnr, extmark_id, ns)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, extmark_id)
end

--- Clear all extmarks in a namespace for a buffer.
---@param bufnr number
---@param ns number Namespace ID
function M.clear_namespace(bufnr, ns)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

--- Get all extmarks in a namespace for a buffer.
---@param bufnr number
---@param ns number Namespace ID
---@return table[] List of { id, row, col } (0-indexed)
function M.get_extmarks(bufnr, ns)
    return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

return M
