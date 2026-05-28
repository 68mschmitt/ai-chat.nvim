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

-- Keep test runs independent of the user's persisted provider/model choice.
require("ai-chat.state").init(vim.fn.tempname() .. "/ai-chat-test-state")

-- Load the plugin with test-safe config
require("ai-chat").setup({
    default_provider = "ollama",
    default_model = "llama3.2",
    history = { enabled = false },
    log = { enabled = false },
})
