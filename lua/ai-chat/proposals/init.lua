--- ai-chat.nvim --- Proposal data model and lifecycle
--- Owns the proposal queue state. Pure data module --- no UI calls, no
--- coordinator requires. All dependencies are received as function arguments.
---
--- Proposals are ephemeral --- they live for the session and are not
--- persisted to disk.

local M = {}

---@class AiChatProposal
---@field id string UUID
---@field file string Absolute path to target file
---@field description string One-line human-readable intent
---@field detail string? Full AI explanation (multi-line, from preceding text)
---@field original_lines string[] Lines being replaced
---@field proposed_lines string[] Replacement lines
---@field range { start: number, end_: number } 1-indexed line range in original
---@field status "pending"|"accepted"|"rejected"|"expired"
---@field created_at number os.time() timestamp
---@field conversation_id string Which conversation produced this
---@field bufnr number? Buffer number if file is loaded (nil for unloaded files)
---@field extmark_id number? Extmark ID for the sign (set by ui/proposals.lua)
---@field expanded boolean? Whether the inline preview is expanded (default false)

---@type AiChatProposal[]
local proposals = {}

--- Set of bufnrs we have attached to for conflict detection.
---@type table<number, boolean>
local attached_buffers = {}

-- ---- CRUD ----------------------------------------------------------------

--- Generate a simple unique ID.
---@return string
local function uuid()
    return string.format("%08x-%04x-%04x", os.time(), math.random(0, 0xffff), math.random(0, 0xffff))
end

--- Add a proposal to the queue.
---@param proposal table Partial proposal (id and status are set automatically)
---@return string id The assigned proposal ID
function M.add(proposal)
    proposal.id = proposal.id or uuid()
    proposal.status = "pending"
    proposal.created_at = proposal.created_at or os.time()
    table.insert(proposals, proposal)
    return proposal.id
end

--- Get a proposal by ID.
---@param id string
---@return AiChatProposal?
function M.get(id)
    for _, p in ipairs(proposals) do
        if p.id == id then
            return p
        end
    end
    return nil
end

--- Find a proposal at a given cursor position (buffer + line).
--- Returns the first pending proposal whose range contains the line.
---@param bufnr number
---@param line number 1-indexed line number
---@return AiChatProposal?
function M.get_at_cursor(bufnr, line)
    for _, p in ipairs(proposals) do
        if p.bufnr == bufnr and p.status == "pending" and line >= p.range.start and line <= p.range.end_ then
            return p
        end
    end
    -- Fall back to expired proposals (for gx dismiss)
    for _, p in ipairs(proposals) do
        if p.bufnr == bufnr and p.status == "expired" and line >= p.range.start and line <= p.range.end_ then
            return p
        end
    end
    return nil
end

--- Get all pending proposals.
---@return AiChatProposal[]
function M.get_pending()
    local result = {}
    for _, p in ipairs(proposals) do
        if p.status == "pending" then
            table.insert(result, p)
        end
    end
    return result
end

--- Get all proposals (any status) for a specific buffer.
---@param bufnr number
---@return AiChatProposal[]
function M.get_for_buffer(bufnr)
    local result = {}
    for _, p in ipairs(proposals) do
        if p.bufnr == bufnr then
            table.insert(result, p)
        end
    end
    return result
end

--- Get all proposals (any status) for a specific file path.
--- Works for proposals whose target buffer is not yet loaded.
---@param file string Absolute file path
---@return AiChatProposal[]
function M.get_for_file(file)
    local result = {}
    for _, p in ipairs(proposals) do
        if p.file == file then
            table.insert(result, p)
        end
    end
    return result
end

--- Count pending proposals.
---@return number
function M.count_pending()
    local n = 0
    for _, p in ipairs(proposals) do
        if p.status == "pending" then
            n = n + 1
        end
    end
    return n
end

--- Check if a buffer has any pending proposals.
---@param bufnr number
---@return boolean
function M.has_pending(bufnr)
    for _, p in ipairs(proposals) do
        if p.bufnr == bufnr and p.status == "pending" then
            return true
        end
    end
    return false
end

--- Set proposal status to accepted.
---@param id string
---@return AiChatProposal? The updated proposal, or nil if not found
function M.accept(id)
    local p = M.get(id)
    if p then
        p.status = "accepted"
    end
    return p
end

--- Set proposal status to rejected.
---@param id string
---@return AiChatProposal? The updated proposal, or nil if not found
function M.reject(id)
    local p = M.get(id)
    if p then
        p.status = "rejected"
    end
    return p
end

--- Set proposal status to expired.
---@param id string
---@return AiChatProposal? The updated proposal, or nil if not found
function M.expire(id)
    local p = M.get(id)
    if p then
        p.status = "expired"
    end
    return p
end

--- Toggle the expanded/collapsed state of a proposal's inline preview.
---@param id string
---@return AiChatProposal? The updated proposal, or nil if not found
function M.toggle_expanded(id)
    local p = M.get(id)
    if p then
        p.expanded = not p.expanded
    end
    return p
end

--- Remove all proposals and reset state.
function M.clear()
    proposals = {}
    attached_buffers = {}
end

--- Get all proposals (read-only snapshot).
---@return AiChatProposal[]
function M.all()
    return vim.deepcopy(proposals)
end

--- Set placement info (bufnr, extmark_id) on a proposal.
--- Called by the UI layer after placing signs.
---@param id string
---@param bufnr number
---@param extmark_id number?
function M.set_placement(id, bufnr, extmark_id)
    local p = M.get(id)
    if p then
        p.bufnr = bufnr
        p.extmark_id = extmark_id
    end
end

-- ---- Conflict Detection --------------------------------------------------

--- Attach to a buffer for conflict detection.
--- When the user edits lines overlapping a pending proposal, that proposal
--- is expired. When a proposal is *accepted* (lines change from the accept),
--- other proposals on the same buffer have their ranges adjusted rather than
--- expired.
---
---@param bufnr number
---@param on_expire fun(proposal: AiChatProposal) Callback when a proposal expires
function M.attach_buffer(bufnr, on_expire)
    if attached_buffers[bufnr] then
        return
    end
    attached_buffers[bufnr] = true

    vim.api.nvim_buf_attach(bufnr, false, {
        --- on_lines callback: (event, bufnr, changedtick, firstline, lastline, new_lastline)
        --- firstline, lastline, new_lastline are all 0-indexed.
        on_lines = function(_, buf, _, firstline, lastline, new_lastline)
            if not attached_buffers[buf] then
                return true -- detach
            end

            local edit_start = firstline + 1 -- convert to 1-indexed
            local edit_end = lastline -- lastline is exclusive in 0-indexed, so = end in 1-indexed
            local line_delta = new_lastline - lastline

            for _, p in ipairs(proposals) do
                if p.bufnr == buf and p.status == "pending" then
                    -- Check overlap: proposal range [p.range.start, p.range.end_]
                    -- vs edited range [edit_start, edit_end]
                    if edit_start <= p.range.end_ and edit_end >= p.range.start then
                        -- Overlap detected --- check if this is from an accept
                        -- (accepts set _accepting_id before nvim_buf_set_lines)
                        if M._accepting_id and M._accepting_id == p.id then
                            -- This is the proposal being accepted --- skip
                        else
                            M.expire(p.id)
                            on_expire(p)
                        end
                    elseif p.range.start > edit_end and line_delta ~= 0 then
                        -- Edit is entirely above this proposal --- shift range
                        p.range.start = p.range.start + line_delta
                        p.range.end_ = p.range.end_ + line_delta
                    end
                end
            end
        end,

        on_detach = function(_, buf)
            attached_buffers[buf] = nil
        end,
    })
end

--- Detach from a buffer (stop conflict detection).
---@param bufnr number
function M.detach_buffer(bufnr)
    attached_buffers[bufnr] = nil
end

--- Check if a buffer is currently attached.
---@param bufnr number
---@return boolean
function M.is_attached(bufnr)
    return attached_buffers[bufnr] == true
end

-- Internal: set by coordinator before nvim_buf_set_lines for an accept,
-- so the on_lines callback knows not to expire the proposal being accepted.
---@type string?
M._accepting_id = nil

return M
