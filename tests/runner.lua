--- Test runner for ai-chat.nvim
--- Discovers and runs *_spec.lua files using the custom harness.
---
--- Usage:
---   nvim --headless --noplugin -u tests/minimal_init.lua \
---     -c "luafile tests/runner.lua"
---
--- Single file:
---   nvim --headless --noplugin -u tests/minimal_init.lua \
---     -c "lua _G._test_file = 'tests/config_spec.lua'" \
---     -c "luafile tests/runner.lua"

local root = vim.fn.getcwd()
local harness = dofile(root .. "/tests/harness.lua")

-- Set globals so spec files work without require
describe = harness.describe
it = harness.it
before_each = harness.before_each
after_each = harness.after_each
assert = harness.assert

-- ── File discovery ─────────────────────────────────────────────────────

local function find_specs(dir)
    local specs = {}
    local handle = vim.loop.fs_scandir(dir)
    if not handle then
        return specs
    end
    while true do
        local name, ftype = vim.loop.fs_scandir_next(handle)
        if not name then
            break
        end
        local path = dir .. "/" .. name
        if ftype == "directory" then
            vim.list_extend(specs, find_specs(path))
        elseif name:match("_spec%.lua$") then
            specs[#specs + 1] = path
        end
    end
    table.sort(specs)
    return specs
end

-- ── Determine target ───────────────────────────────────────────────────

local target = _G._test_file or (root .. "/tests")
local specs = {}

if vim.fn.filereadable(target) == 1 then
    specs = { target }
elseif vim.fn.isdirectory(target) == 1 then
    specs = find_specs(target)
else
    io.stderr:write("Error: " .. target .. " not found\n")
    vim.cmd("cquit! 1")
    return
end

if #specs == 0 then
    print("No spec files found.")
    vim.cmd("qa!")
    return
end

-- ── Run ────────────────────────────────────────────────────────────────

local total_passed, total_failed = 0, 0
local all_errors = {}

for _, path in ipairs(specs) do
    local rel = path:sub(#root + 2) -- relative path for display
    harness.reset()

    local load_ok, load_err = pcall(dofile, path)
    if not load_ok then
        total_failed = total_failed + 1
        all_errors[#all_errors + 1] = { name = rel .. " (load error)", err = tostring(load_err) }
        io.write(string.format("  LOAD ERROR  %s\n    %s\n", rel, tostring(load_err)))
    else
        local results = harness.run()
        total_passed = total_passed + results.passed
        total_failed = total_failed + results.failed

        if results.failed > 0 then
            io.write(string.format("  FAIL  %s (%d/%d)\n", rel, results.passed, results.total))
            for _, e in ipairs(results.errors) do
                all_errors[#all_errors + 1] = e
                io.write(string.format("    x %s\n      %s\n", e.name, e.err))
            end
        else
            io.write(string.format("  OK    %s (%d tests)\n", rel, results.total))
        end
    end
end

-- ── Summary ────────────────────────────────────────────────────────────

io.write(string.format("\n%d passed, %d failed, %d total\n", total_passed, total_failed, total_passed + total_failed))

if total_failed > 0 then
    vim.cmd("cquit! 1")
else
    vim.cmd("qa!")
end
