--- ai-chat.nvim — Context coordinator
--- Parses @context references from user messages and collects content.

local M = {}

-- Lazy-loaded collector references
local _collectors = nil

local function get_collectors()
    if _collectors then
        return _collectors
    end
    _collectors = {
        buffer = require("ai-chat.context.buffer"),
        selection = require("ai-chat.context.selection"),
    }
    -- Optionally load extended collectors (diagnostics/diff/file are v0.2+
    -- but we load them if present to avoid breaking imports)
    local ok_diag, diag = pcall(require, "ai-chat.context.diagnostics")
    if ok_diag then
        _collectors.diagnostics = diag
    end
    local ok_diff, diff = pcall(require, "ai-chat.context.diff")
    if ok_diff then
        _collectors.diff = diff
    end
    local ok_file, file = pcall(require, "ai-chat.context.file")
    if ok_file then
        _collectors.file = file
    end
    return _collectors
end

--- Parse @context tags from a message and collect their content.
---@param text string  The user's message text
---@param explicit_contexts? string[]  Explicitly requested context names (e.g., {"buffer"})
---@return AiChatContext[]
function M.collect(text, explicit_contexts)
    local results = {}
    local collectors = get_collectors()

    -- Parse @tags from the message text
    local parsed_tags = M._parse_tags(text)

    -- Merge with explicit contexts (deduplicate by name)
    if explicit_contexts then
        local seen = {}
        for _, tag in ipairs(parsed_tags) do
            seen[tag.name] = true
        end
        for _, name in ipairs(explicit_contexts) do
            if not seen[name] then
                table.insert(parsed_tags, { name = name })
                seen[name] = true
            end
        end
    end

    -- Collect content for each tag
    for _, tag in ipairs(parsed_tags) do
        local collector = collectors[tag.name]
        if collector then
            local ok, ctx = pcall(collector.collect, tag.args)
            if ok and ctx then
                table.insert(results, ctx)
            end
        end
    end

    return results
end

--- Parse @context tags from message text.
--- Supports: @buffer, @selection, @diagnostics, @diff, @file:path
---@param text string
---@return { name: string, args?: string }[]
function M._parse_tags(text)
    local tags = {}

    -- Match @word patterns
    for tag in text:gmatch("@(%S+)") do
        -- Handle @file:path/to/file.lua
        local name, args = tag:match("^(%w+):(.+)$")
        if name then
            table.insert(tags, { name = name, args = args })
        else
            table.insert(tags, { name = tag })
        end
    end

    return tags
end

--- Strip @context tags from a message, returning clean text.
---@param text string
---@return string
function M.strip_tags(text)
    -- Remove @word and @word:args patterns, then trim leading whitespace
    return text:gsub("@%S+%s*", ""):gsub("^%s+", "")
end

--- List all available context types.
---@return string[]
function M.available()
    return vim.tbl_keys(get_collectors())
end

return M
