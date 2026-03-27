--- ai-chat.nvim --- Proposal response parser
--- Extracts proposals from AI responses to /propose commands.
--- Pure text parsing + vim.fn for file resolution. No coordinator requires.
---
--- Parsing strategies (tried in order):
---   1. Exact: ```lang file=path lines=N-M
---   2. File only: ```lang file=path (whole-file replacement)
---   3. Path after lang: ```lang path/to/file.lua (fallback)
---
--- When lines=N-M is absent, falls back to exact content matching against
--- the file. Multiple exact matches or no match produces a warning.

local M = {}

--- Parse a /propose response into proposals.
---@param response_text string The full AI response text
---@param conversation_id string The conversation that produced this response
---@return { proposals: table[], warnings: string[] }
function M.parse(response_text, conversation_id)
    local proposals = {}
    local warnings = {}

    -- Extract all fenced code blocks with their fence info lines
    local blocks = M._extract_code_blocks(response_text)

    for _, block in ipairs(blocks) do
        local file, line_start, line_end = M._parse_fence_info(block.fence_info)
        if not file then
            -- Not annotated --- skip (regular code block, not a proposal)
            goto continue
        end

        -- Resolve file path relative to cwd
        local abs_path = M._resolve_path(file)
        if not abs_path then
            table.insert(warnings, string.format("File not found: %s", file))
            goto continue
        end

        -- Read original lines from the file
        local original_lines, range = M._read_original(abs_path, line_start, line_end, block.content)
        if not original_lines then
            table.insert(warnings, string.format("Could not locate target in %s", file))
            goto continue
        end

        -- Extract description (one-liner) and detail (full text) from surrounding text
        local description = M._extract_description(block.preceding_text)
        local detail = M._extract_detail(block.preceding_text)

        table.insert(proposals, {
            file = abs_path,
            description = description,
            detail = detail,
            original_lines = original_lines,
            proposed_lines = vim.split(block.content, "\n", { plain = true }),
            range = range,
            conversation_id = conversation_id,
        })

        ::continue::
    end

    return { proposals = proposals, warnings = warnings }
end

--- Extract fenced code blocks from response text.
--- Returns blocks with their fence info, content, and preceding text.
---@param text string
---@return { fence_info: string, content: string, preceding_text: string }[]
function M._extract_code_blocks(text)
    local blocks = {}
    local lines = vim.split(text, "\n", { plain = true })
    local i = 1

    while i <= #lines do
        local fence_info = lines[i]:match("^```(.+)$")
        if fence_info then
            -- Collect preceding text (for description extraction)
            local preceding = {}
            local j = i - 1
            while j >= 1 and not lines[j]:match("^```") do
                table.insert(preceding, 1, lines[j])
                j = j - 1
            end

            -- Collect block content
            local content_lines = {}
            i = i + 1
            while i <= #lines and not lines[i]:match("^```%s*$") do
                table.insert(content_lines, lines[i])
                i = i + 1
            end

            table.insert(blocks, {
                fence_info = vim.trim(fence_info),
                content = table.concat(content_lines, "\n"),
                preceding_text = table.concat(preceding, "\n"),
            })
        end
        i = i + 1
    end

    return blocks
end

--- Strip quotes, backticks, and other wrapper characters from a path.
---@param path string
---@return string
local function clean_path(path)
    -- Strip surrounding quotes or backticks
    path = path:gsub("^[\"'`]+", ""):gsub("[\"'`]+$", "")
    -- Strip trailing commas or colons (common LLM artifacts)
    path = path:gsub("[,:]+$", "")
    return path
end

--- Parse fence info to extract file path and optional line range.
--- Strategies (tried in order):
---   1. "lang file=path lines=N-M" or "file=path" (with optional quotes)
---   2. "lang file: path" or "file: path" (colon variant common in LLM output)
---   3. "lang path/to/file.ext" (path after language, must contain / or known extension)
---@param fence_info string
---@return string? file, number? line_start, number? line_end
function M._parse_fence_info(fence_info)
    -- Strategy 1: file=path (with optional quotes)
    local file = fence_info:match('file="([^"]+)"')
        or fence_info:match("file='([^']+)'")
        or fence_info:match("file=(%S+)")
    if file then
        file = clean_path(file)
        local ls, le = fence_info:match("lines=(%d+)-(%d+)")
        return file, ls and tonumber(ls), le and tonumber(le)
    end

    -- Strategy 2: "file: path" or "File: path" (colon variant)
    file = fence_info:match("[Ff]ile:%s*(%S+)")
    if file then
        file = clean_path(file)
        local ls, le = fence_info:match("lines=(%d+)-(%d+)") or fence_info:match("[Ll]ines:%s*(%d+)-(%d+)")
        return file, ls and tonumber(ls), le and tonumber(le)
    end

    -- Strategy 3: path after language (must contain / or end with known extension)
    local parts = vim.split(fence_info, "%s+")
    if #parts >= 2 then
        local candidate = clean_path(parts[2])
        if candidate:match("/") or candidate:match("%.%w+$") then
            -- Check it's not a flag like --option
            if not candidate:match("^%-") then
                return candidate, nil, nil
            end
        end
    end

    return nil, nil, nil
end

--- Resolve a file path relative to cwd.
--- Tries multiple strategies to find the file.
---@param file string
---@return string? Absolute path, or nil if file doesn't exist
function M._resolve_path(file)
    file = clean_path(file)

    -- Already absolute
    if file:sub(1, 1) == "/" then
        if vim.fn.filereadable(file) == 1 then
            return file
        end
        return nil
    end

    -- Strategy 1: Relative to cwd
    local cwd = vim.fn.getcwd()
    local abs = cwd .. "/" .. file
    if vim.fn.filereadable(abs) == 1 then
        return vim.fn.fnamemodify(abs, ":p")
    end

    -- Strategy 2: Search loaded buffers for a matching tail
    -- Handles cases where the AI outputs "config.lua" but the actual path
    -- is "lua/ai-chat/config.lua"
    local tail = vim.fn.fnamemodify(file, ":t")
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" and vim.fn.fnamemodify(name, ":t") == tail then
                -- Check if the full path ends with the requested path
                if name:sub(-#file) == file then
                    return name
                end
            end
        end
    end

    -- Strategy 3: Find relative to cwd using vim.fn.glob
    local matches = vim.fn.glob(cwd .. "/**/" .. file, false, true)
    if #matches == 1 then
        return matches[1]
    end

    return nil
end

--- Read original lines from a file, using line range or content matching.
---@param abs_path string
---@param line_start number?
---@param line_end number?
---@param proposed_content string
---@return string[]? original_lines, { start: number, end_: number }? range
function M._read_original(abs_path, line_start, line_end, proposed_content)
    local file_lines = vim.fn.readfile(abs_path)
    if not file_lines or #file_lines == 0 then
        return nil, nil
    end

    -- Strategy A: Use line range if provided
    if line_start and line_end then
        -- Clamp to file bounds
        line_start = math.max(1, line_start)
        line_end = math.min(#file_lines, line_end)
        local original = {}
        for i = line_start, line_end do
            table.insert(original, file_lines[i])
        end
        return original, { start = line_start, end_ = line_end }
    end

    -- Strategy B: No line range given.
    -- If the proposed content covers most of the file (>=80%), treat as
    -- whole-file replacement. Otherwise, we can't determine the target
    -- range — return nil so the caller produces a warning.
    local proposed_lines = vim.split(proposed_content, "\n", { plain = true })
    if #proposed_lines >= #file_lines * 0.8 then
        -- Looks like a whole-file replacement
        return file_lines, { start = 1, end_ = #file_lines }
    end

    -- Can't determine target range — caller will skip with warning
    return nil, nil
end

--- Extract a description from text preceding a code block.
--- Takes the last non-empty line before the block.
---@param preceding_text string
---@return string
function M._extract_description(preceding_text)
    local lines = vim.split(preceding_text, "\n", { plain = true })
    -- Walk backward to find the last meaningful line
    for i = #lines, 1, -1 do
        local line = vim.trim(lines[i])
        if line ~= "" then
            -- Strip markdown formatting
            line = line:gsub("^%*%*(.-)%*%*$", "%1") -- bold
            line = line:gsub("^#+%s+", "") -- headers
            line = line:gsub("^%d+%.%s+", "") -- numbered lists
            line = line:gsub("^[%-*]%s+", "") -- bullet lists
            line = line:gsub(":$", "") -- trailing colon
            -- Truncate to reasonable length
            if #line > 80 then
                line = line:sub(1, 77) .. "..."
            end
            return line
        end
    end
    return "AI-proposed change"
end

--- Strip markdown formatting from a single line.
---@param line string
---@return string
local function strip_markdown(line)
    line = line:gsub("%*%*(.-)%*%*", "%1") -- **bold**
    line = line:gsub("%*(.-)%*", "%1") -- *italic*
    line = line:gsub("`(.-)`", "%1") -- `code`
    line = line:gsub("^#+%s+", "") -- ### headers
    line = line:gsub("^%d+%.%s+", "") -- 1. numbered lists
    line = line:gsub("^[%-*]%s+", "") -- - bullet lists
    return line
end

--- Soft-wrap a line of text to a max width.
---@param text string
---@param max_width number
---@return string[]
local function soft_wrap(text, max_width)
    if #text <= max_width then
        return { text }
    end
    local result = {}
    local remaining = text
    while #remaining > max_width do
        -- Find last space within max_width
        local break_at = max_width
        for i = max_width, 1, -1 do
            if remaining:sub(i, i) == " " then
                break_at = i
                break
            end
        end
        table.insert(result, remaining:sub(1, break_at))
        remaining = vim.trim(remaining:sub(break_at + 1))
    end
    if #remaining > 0 then
        table.insert(result, remaining)
    end
    return result
end

--- Extract full detail text from preceding text.
--- Strips markdown, removes empty leading/trailing lines, soft-wraps to ~70 chars.
---@param preceding_text string
---@return string? detail Multi-line text or nil if empty
function M._extract_detail(preceding_text)
    if not preceding_text or preceding_text == "" then
        return nil
    end

    local raw_lines = vim.split(preceding_text, "\n", { plain = true })
    local cleaned = {}
    for _, line in ipairs(raw_lines) do
        local stripped = strip_markdown(vim.trim(line))
        table.insert(cleaned, stripped)
    end

    -- Trim leading and trailing empty lines
    while #cleaned > 0 and cleaned[1] == "" do
        table.remove(cleaned, 1)
    end
    while #cleaned > 0 and cleaned[#cleaned] == "" do
        table.remove(cleaned)
    end

    if #cleaned == 0 then
        return nil
    end

    -- Join into paragraphs then soft-wrap at ~70 chars
    local wrapped = {}
    for _, line in ipairs(cleaned) do
        if line == "" then
            table.insert(wrapped, "")
        else
            for _, wl in ipairs(soft_wrap(line, 70)) do
                table.insert(wrapped, wl)
            end
        end
    end

    return table.concat(wrapped, "\n")
end

return M
