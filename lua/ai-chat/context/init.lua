--- ai-chat.nvim — Context coordinator
--- Parses @context references from user messages and collects content.

local M = {}

local collectors = {
    buffer = require("ai-chat.context.buffer"),
    selection = require("ai-chat.context.selection"),
    diagnostics = require("ai-chat.context.diagnostics"),
    diff = require("ai-chat.context.diff"),
    file = require("ai-chat.context.file"),
}

--- Parse @context tags from a message and collect their content.
---@param text string  The user's message text
---@param explicit_contexts? string[]  Explicitly requested contexts (e.g., from opts)
---@return AiChatContext[]
function M.collect(text, explicit_contexts)
    local results = {}

    -- Parse @tags from the message text
    local parsed_tags = M._parse_tags(text)

    -- Merge with explicit contexts
    if explicit_contexts then
        for _, ctx in ipairs(explicit_contexts) do
            if not vim.tbl_contains(parsed_tags, ctx) then
                table.insert(parsed_tags, { name = ctx })
            end
        end
    end

    -- Collect content for each tag
    for _, tag in ipairs(parsed_tags) do
        local collector = collectors[tag.name]
        if collector then
            local ctx = collector.collect(tag.args)
            if ctx then
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

    -- Match @word patterns at the start of the text or after whitespace
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
    return text:gsub("@%S+%s*", ""):gsub("^%s+", "")
end

--- List all available context types.
---@return string[]
function M.available()
    return vim.tbl_keys(collectors)
end

return M
