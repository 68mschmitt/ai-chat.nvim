--- Minimal test harness for ai-chat.nvim
--- Provides describe/it/before_each/after_each and assert wrappers.
--- Zero external dependencies.

local M = {}

-- ── Helpers ────────────────────────────────────────────────────────────

local function copy(t)
    local out = {}
    for i = 1, #t do
        out[i] = t[i]
    end
    return out
end

local function fmt(v)
    if type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

-- ── Test tree ──────────────────────────────────────────────────────────

local tests = {}
local ctx = { before_eachs = {}, after_eachs = {}, prefix = "" }

function M.describe(name, fn)
    local parent = ctx
    ctx = {
        before_eachs = copy(parent.before_eachs),
        after_eachs = copy(parent.after_eachs),
        prefix = parent.prefix == "" and name or (parent.prefix .. " > " .. name),
    }
    fn()
    ctx = parent
end

function M.it(name, fn)
    tests[#tests + 1] = {
        name = ctx.prefix .. " > " .. name,
        fn = fn,
        before_eachs = copy(ctx.before_eachs),
        after_eachs = copy(ctx.after_eachs),
    }
end

function M.before_each(fn)
    ctx.before_eachs[#ctx.before_eachs + 1] = fn
end

function M.after_each(fn)
    ctx.after_eachs[#ctx.after_eachs + 1] = fn
end

-- ── Assert ─────────────────────────────────────────────────────────────

-- Callable as assert(val, msg) and as assert.method(...)
local A = setmetatable({}, {
    __call = function(_, val, msg)
        if not val then
            error(msg or "assertion failed", 2)
        end
        return val
    end,
})

function A.equals(expected, actual, msg)
    if expected ~= actual then
        error(msg or string.format("expected %s, got %s", fmt(expected), fmt(actual)), 2)
    end
end

function A.is_true(val, msg)
    if val ~= true then
        error(msg or string.format("expected true, got %s", fmt(val)), 2)
    end
end

function A.is_false(val, msg)
    if val ~= false then
        error(msg or string.format("expected false, got %s", fmt(val)), 2)
    end
end

function A.truthy(val, msg)
    if not val then
        error(msg or string.format("expected truthy, got %s", fmt(val)), 2)
    end
end

function A.is_table(val, msg)
    if type(val) ~= "table" then
        error(msg or string.format("expected table, got %s", type(val)), 2)
    end
end

function A.is_nil(val, msg)
    if val ~= nil then
        error(msg or string.format("expected nil, got %s", fmt(val)), 2)
    end
end

function A.is_not_nil(val, msg)
    if val == nil then
        error(msg or "expected non-nil, got nil", 2)
    end
end

function A.is_function(val, msg)
    if type(val) ~= "function" then
        error(msg or string.format("expected function, got %s", type(val)), 2)
    end
end

-- assert.is_not.equals(a, b)
A.is_not = {}
function A.is_not.equals(a, b, msg)
    if a == b then
        error(msg or string.format("expected values to differ, both are %s", fmt(a)), 2)
    end
end

-- assert.has_no.errors(fn)
A.has_no = {}
function A.has_no.errors(fn)
    local ok, err = pcall(fn)
    if not ok then
        error("expected no error, got: " .. tostring(err), 2)
    end
end

M.assert = A

-- ── Runner ─────────────────────────────────────────────────────────────

function M.reset()
    tests = {}
    ctx = { before_eachs = {}, after_eachs = {}, prefix = "" }
end

function M.run()
    local passed, failed, errs = 0, 0, {}

    for _, t in ipairs(tests) do
        -- before_each hooks
        local setup_ok = true
        for _, hook in ipairs(t.before_eachs) do
            local ok, err = pcall(hook)
            if not ok then
                setup_ok = false
                failed = failed + 1
                errs[#errs + 1] = { name = t.name, err = "before_each: " .. tostring(err) }
                break
            end
        end

        if setup_ok then
            local ok, err = pcall(t.fn)
            if ok then
                passed = passed + 1
            else
                failed = failed + 1
                errs[#errs + 1] = { name = t.name, err = tostring(err) }
            end
        end

        -- after_each hooks (always run)
        for _, hook in ipairs(t.after_eachs) do
            pcall(hook)
        end
    end

    return { passed = passed, failed = failed, errors = errs, total = passed + failed }
end

return M
