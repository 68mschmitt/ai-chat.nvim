--- ai-chat.nvim — Audit logging
--- Logs all API interactions to a rotating file for debugging and transparency.

local M = {}

local state = {
    config = {},
    file = nil,
}

--- Initialize the logger.
---@param cfg table  The log section of AiChatConfig
function M.init(cfg)
    state.config = cfg
    if not state.config.enabled then
        return
    end

    state.file = cfg.file or (vim.fn.stdpath("data") .. "/ai-chat/log.txt")

    -- Ensure parent directory exists
    local dir = vim.fn.fnamemodify(state.file, ":h")
    vim.fn.mkdir(dir, "p")
end

local levels = { debug = 1, info = 2, warn = 3, error = 4 }

--- Write a log entry.
---@param level string  "debug"|"info"|"warn"|"error"
---@param msg string
---@param data? any  Optional structured data to log
function M.write(level, msg, data)
    if not state.config.enabled or not state.file then
        return
    end

    local config_level = levels[state.config.level] or 2
    local msg_level = levels[level] or 2

    if msg_level < config_level then
        return
    end

    local entry = string.format("[%s] [%s] %s", os.date("%Y-%m-%d %H:%M:%S"), level:upper(), msg)

    if data then
        local ok, encoded = pcall(vim.inspect, data)
        if ok then
            entry = entry .. " | " .. encoded
        end
    end

    -- Append to log file
    vim.fn.writefile({ entry }, state.file, "a")

    -- Check rotation
    M._maybe_rotate()
end

-- Convenience methods
function M.debug(msg, data)
    M.write("debug", msg, data)
end
function M.info(msg, data)
    M.write("info", msg, data)
end
function M.warn(msg, data)
    M.write("warn", msg, data)
end
function M.error(msg, data)
    M.write("error", msg, data)
end

--- Open the log file in a buffer.
function M.open()
    if not state.file then
        vim.notify("[ai-chat] Logging not initialized", vim.log.levels.WARN)
        return
    end

    if vim.fn.filereadable(state.file) ~= 1 then
        vim.notify("[ai-chat] No log file found", vim.log.levels.INFO)
        return
    end

    vim.cmd("botright split " .. vim.fn.fnameescape(state.file))
    vim.cmd("normal! G") -- Jump to end
end

--- Rotate the log file if it exceeds the size limit.
function M._maybe_rotate()
    if not state.file or not state.config.max_size_mb then
        return
    end

    local size = vim.fn.getfsize(state.file)
    if size < 0 then
        return
    end

    local max_bytes = state.config.max_size_mb * 1024 * 1024
    if size > max_bytes then
        local old = state.file .. ".old"
        vim.fn.rename(state.file, old)
    end
end

return M
