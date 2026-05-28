--- ai-chat.nvim — Auth token persistence
--- Stores provider authentication material under stdpath("data")/ai-chat/auth.json.
--- Lenient on read, strict on write. Secrets never go through config.

local M = {}

local custom_path = nil

local function auth_path()
    if custom_path then
        return custom_path
    end
    local dir = vim.fn.stdpath("data") .. "/ai-chat"
    vim.fn.mkdir(dir, "p")
    return dir .. "/auth.json"
end

local function read_all()
    local path = auth_path()
    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end
    local lines = vim.fn.readfile(path)
    if #lines == 0 then
        return {}
    end
    local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not ok or type(data) ~= "table" then
        return {}
    end
    return data
end

local function write_all(data)
    local path = auth_path()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local tmp = path .. ".tmp"
    vim.fn.writefile({ vim.json.encode(data) }, tmp)
    vim.fn.rename(tmp, path)
end

function M.get(provider)
    return vim.deepcopy(read_all()[provider])
end

function M.set(provider, auth)
    local data = read_all()
    data[provider] = auth
    write_all(data)
end

function M.delete(provider)
    local data = read_all()
    data[provider] = nil
    write_all(data)
end

function M.path()
    return auth_path()
end

function M._set_path(path)
    custom_path = path
end

return M
