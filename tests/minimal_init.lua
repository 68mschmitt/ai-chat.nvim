-- Minimal init for running tests.
-- Usage:
--   make test
--   nvim --headless --noplugin -u tests/minimal_init.lua \
--     -c "luafile tests/runner.lua"

-- Set up runtime path
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)

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
