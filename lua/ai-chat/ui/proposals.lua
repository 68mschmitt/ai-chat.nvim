--- ai-chat.nvim --- Proposal UI layer
--- Sign placement, virtual text, quickfix list, and buffer-local keymaps
--- for proposals. Called by the coordinator (init.lua), never by the data
--- model (proposals/init.lua).
---
--- Receives all action callbacks as function arguments to avoid requiring
--- coordinator modules.

local overlays = require("ai-chat.ui.overlays")

local M = {}

local ns = overlays.ns_proposals

--- Augroup for deferred sign placement on BufRead.
local augroup_name = "ai-chat-proposals"

--- Track which buffers have proposal keymaps set.
---@type table<number, boolean>
local keymapped_buffers = {}

-- ---- Sign Placement ------------------------------------------------------

--- Truncate a description to a short signpost label.
---@param desc string
---@param max_len? number  Default 35
---@return string
local function truncate_desc(desc, max_len)
    max_len = max_len or 35
    if #desc <= max_len then
        return desc
    end
    return desc:sub(1, max_len - 1) .. "\226\128\166" -- …
end

--- Place a sign and virtual text for a single proposal on a loaded buffer.
---@param bufnr number
---@param proposal AiChatProposal
function M.place(bufnr, proposal)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    local line = proposal.range.start
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if line > line_count then
        line = line_count
    end

    -- Short signpost label — full description available via gi (inspect)
    local desc = proposal.description or "pending change"
    local virt_text = truncate_desc(desc)

    local extmark_id = overlays.place_sign(bufnr, line, ns, {
        sign_text = "\226\150\141", -- ▍
        sign_hl = "AiChatProposalSign",
        virt_text = virt_text,
        virt_hl = "Special",
    })
    proposal.extmark_id = extmark_id
    proposal.bufnr = bufnr
end

--- Place signs for all proposals, handling loaded and unloaded buffers.
--- Registers BufRead autocmds for files not yet open.
---@param all_proposals AiChatProposal[]
---@param setup_keymaps_fn fun(bufnr: number) Callback to set buffer-local keymaps
function M.place_all(all_proposals, setup_keymaps_fn)
    -- Clear any existing deferred autocmds
    pcall(vim.api.nvim_del_augroup_by_name, augroup_name)
    vim.api.nvim_create_augroup(augroup_name, { clear = true })

    -- Group proposals by file
    local by_file = {}
    for _, p in ipairs(all_proposals) do
        if p.status == "pending" then
            by_file[p.file] = by_file[p.file] or {}
            table.insert(by_file[p.file], p)
        end
    end

    for file, file_proposals in pairs(by_file) do
        -- Check if the file is already loaded in a buffer
        local bufnr = vim.fn.bufnr(file)
        if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
            -- Place signs immediately
            for _, p in ipairs(file_proposals) do
                M.place(bufnr, p)
            end
            setup_keymaps_fn(bufnr)
        else
            -- Register deferred placement for when the file is opened
            M._register_deferred(file, file_proposals, setup_keymaps_fn)
        end
    end

    M.update_quickfix(all_proposals)
end

-- ---- Inline Preview (expand/collapse) ------------------------------------

--- Build virt_lines content for an expanded proposal preview.
--- Layout:
---   ┊                          (spacer)
---   ┊ Full description text    (Comment)
---   ┊ continued on next line
---   ┊                          (spacer)
---   ┊ ── proposed ───────────  (NonText)
---   ┊   proposed code line 1   (DiffAdd)
---   ┊   proposed code line 2
---   ┊                          (spacer)
---@param proposal AiChatProposal
---@return table[][] virt_lines (each entry is a list of {text, hl_group} chunks)
local function build_preview_lines(proposal)
    local lines = {}
    local prefix = "  \226\148\138 " -- ┊ with indent

    -- Leading spacer
    table.insert(lines, { { prefix, "NonText" } })

    -- Full detail text (multi-line), fall back to description
    local text = proposal.detail or proposal.description or "AI-proposed change"
    for _, desc_line in ipairs(vim.split(text, "\n", { plain = true })) do
        if desc_line == "" then
            table.insert(lines, { { prefix, "NonText" } })
        else
            table.insert(lines, { { prefix .. desc_line, "Comment" } })
        end
    end

    -- Spacer before code
    table.insert(lines, { { prefix, "NonText" } })

    -- Labeled separator
    table.insert(
        lines,
        { { prefix .. "\226\148\128\226\148\128 proposed " .. string.rep("\226\148\128", 32), "NonText" } }
    )

    -- Proposed code
    for _, code_line in ipairs(proposal.proposed_lines) do
        table.insert(lines, { { prefix .. "  " .. code_line, "DiffAdd" } })
    end

    -- Trailing spacer
    table.insert(lines, { { prefix, "NonText" } })

    return lines
end

--- Toggle the inline preview (virt_lines) for a proposal.
---@param bufnr number
---@param proposal AiChatProposal
function M.toggle_preview(bufnr, proposal)
    if not proposal.extmark_id then
        return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    if proposal.expanded then
        -- Show virt_lines
        local virt_lines = build_preview_lines(proposal)
        overlays.update_sign(bufnr, proposal.extmark_id, ns, {
            virt_lines = virt_lines,
        })
    else
        -- Hide virt_lines
        overlays.update_sign(bufnr, proposal.extmark_id, ns, {
            virt_lines = false,
        })
    end
end

--- Update a proposal's sign to show expired state.
---@param bufnr number
---@param proposal AiChatProposal
function M.expire_sign(bufnr, proposal)
    if not proposal.extmark_id then
        return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    overlays.update_sign(bufnr, proposal.extmark_id, ns, {
        sign_hl = "AiChatProposalExpired",
        virt_text = "ai-chat: proposal outdated",
        virt_hl = "AiChatProposalExpired",
    })
end

--- Remove the sign for a single proposal.
---@param bufnr number
---@param proposal AiChatProposal
function M.remove(bufnr, proposal)
    if proposal.extmark_id and vim.api.nvim_buf_is_valid(bufnr) then
        overlays.remove_sign(bufnr, proposal.extmark_id, ns)
        proposal.extmark_id = nil
    end
end

--- Remove all proposal signs from all buffers.
function M.remove_all()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            overlays.clear_namespace(bufnr, ns)
        end
    end
    pcall(vim.api.nvim_del_augroup_by_name, augroup_name)
end

-- ---- Quickfix Integration ------------------------------------------------

--- Update the quickfix list with all pending proposals.
--- Sorted by file path then line number for predictable navigation.
---@param all_proposals AiChatProposal[]
function M.update_quickfix(all_proposals)
    local items = {}
    for _, p in ipairs(all_proposals) do
        if p.status == "pending" then
            table.insert(items, {
                filename = p.file,
                lnum = p.range.start,
                text = p.description or "AI-proposed change",
            })
        end
    end

    -- Sort by filename then line number
    table.sort(items, function(a, b)
        if a.filename == b.filename then
            return a.lnum < b.lnum
        end
        return a.filename < b.filename
    end)

    vim.fn.setqflist({}, "r", {
        title = string.format("ai-chat proposals (%d pending)", #items),
        items = items,
    })
end

-- ---- Buffer-Local Keymaps ------------------------------------------------

--- Set up buffer-local keymaps for proposal interaction.
--- Keymaps are: gp (review via diff), ga (accept at cursor), gx (reject/dismiss),
--- gi (inspect — toggle inline preview).
--- Callbacks are injected to avoid requiring coordinator modules.
---@param bufnr number
---@param actions { review: fun(bufnr: number), accept: fun(bufnr: number), reject: fun(bufnr: number), inspect: fun(bufnr: number) }
function M.setup_buf_keymaps(bufnr, actions)
    if keymapped_buffers[bufnr] then
        return
    end
    keymapped_buffers[bufnr] = true

    local map_opts = { buffer = bufnr, silent = true }

    vim.keymap.set("n", "gp", function()
        actions.review(bufnr)
    end, vim.tbl_extend("force", map_opts, { desc = "[ai-chat] Review proposal at cursor" }))

    vim.keymap.set("n", "ga", function()
        actions.accept(bufnr)
    end, vim.tbl_extend("force", map_opts, { desc = "[ai-chat] Accept proposal at cursor" }))

    vim.keymap.set("n", "gx", function()
        actions.reject(bufnr)
    end, vim.tbl_extend("force", map_opts, { desc = "[ai-chat] Reject proposal at cursor" }))

    vim.keymap.set("n", "gi", function()
        actions.inspect(bufnr)
    end, vim.tbl_extend("force", map_opts, { desc = "[ai-chat] Inspect proposal at cursor" }))
end

--- Remove buffer-local proposal keymaps.
---@param bufnr number
function M.clear_buf_keymaps(bufnr)
    if not keymapped_buffers[bufnr] then
        return
    end
    keymapped_buffers[bufnr] = nil

    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    pcall(vim.keymap.del, "n", "gp", { buffer = bufnr })
    pcall(vim.keymap.del, "n", "ga", { buffer = bufnr })
    pcall(vim.keymap.del, "n", "gx", { buffer = bufnr })
    pcall(vim.keymap.del, "n", "gi", { buffer = bufnr })
end

-- ---- Deferred Placement --------------------------------------------------

--- Register a BufRead autocmd to place signs when a file is eventually opened.
---@param file string Absolute file path
---@param file_proposals AiChatProposal[]
---@param setup_keymaps_fn fun(bufnr: number)
function M._register_deferred(file, file_proposals, setup_keymaps_fn)
    vim.api.nvim_create_autocmd("BufRead", {
        group = augroup_name,
        pattern = file,
        once = true,
        callback = function(args)
            local bufnr = args.buf
            vim.schedule(function()
                for _, p in ipairs(file_proposals) do
                    if p.status == "pending" then
                        M.place(bufnr, p)
                    end
                end
                setup_keymaps_fn(bufnr)
            end)
        end,
    })
end

return M
