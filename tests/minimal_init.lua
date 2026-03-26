-- Minimal init for running plenary.busted tests.
-- Usage:
--   make test
--   nvim --headless --noplugin -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

-- Set up runtime path
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)

-- Bootstrap plenary if not present
local plenary_path = root .. "/.deps/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 0 then
    print("Cloning plenary.nvim...")
    vim.fn.system({
        "git", "clone", "--depth", "1",
        "https://github.com/nvim-lua/plenary.nvim",
        plenary_path,
    })
end
vim.opt.rtp:prepend(plenary_path)

-- Minimal settings
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = false

-- Load the plugin with test-safe config
require("ai-chat").setup({
    default_provider = "ollama",
    default_model = "llama3.2",
    history = { enabled = false },
    log = { enabled = false },
})
