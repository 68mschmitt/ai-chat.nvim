# ai-chat.nvim

**The AI is a guest in the editor. The editor is never a guest in the AI.**

Side-panel AI chat for Neovim. Streaming responses, multiple providers, conversation history — all in a native buffer you can yank, search, and navigate with motions. Requires Neovim ≥ 0.10.

<!-- TODO: Add screenshot/GIF of the side panel streaming a response -->

## Features

- **4 providers** — Ollama (default, no API key needed), Anthropic, Amazon Bedrock, OpenAI-compatible
- **Streaming responses** with real-time rendering
- **Extended thinking** support (Claude) with fold/unfold and token counts
- **Code block navigation** — jump between blocks (`]b`/`[b`), yank (`gY`), open in split (`gO`)
- **Conversation history** — persistent, browsable, restorable
- **Visual mode actions** — send selection, explain code, fix code
- **Cost tracking** — per-session estimates with models.dev pricing data
- **Per-project config** via `.ai-chat.lua`
- **Autocmd events** for statusline integration and custom workflows
- **Fully customizable keybindings** — every key overridable, any disableable with `false`
- **`:checkhealth` integration** — validates providers, API keys, treesitter
- **Audit logging** for full transparency

## Requirements

- Neovim ≥ 0.10
- `curl`
- One of: Ollama running locally, `ANTHROPIC_API_KEY`, AWS CLI configured (Bedrock), `OPENAI_API_KEY`
- Optional: treesitter `markdown` and `markdown_inline` parsers for code block syntax highlighting

## Installation

### lazy.nvim (minimal, works with Ollama)

```lua
{
    "68mschmitt/ai-chat.nvim",
    cmd = { "AiChat", "AiChatSend" },
    keys = {
        { "<leader>aa", "<cmd>AiChat<cr>", desc = "Toggle AI Chat" },
    },
    opts = {},
}
```

### lazy.nvim with Anthropic

```lua
{
    "68mschmitt/ai-chat.nvim",
    cmd = { "AiChat", "AiChatSend" },
    keys = {
        { "<leader>aa", "<cmd>AiChat<cr>", desc = "Toggle AI Chat" },
        { "<leader>as", mode = "v", desc = "Send selection to AI Chat" },
    },
    opts = {
        default_provider = "anthropic",
        default_model = "claude-sonnet-4-20250514",
    },
}
```

### packer.nvim

```lua
use({
    "68mschmitt/ai-chat.nvim",
    config = function()
        require("ai-chat").setup()
    end,
})
```

### Any plugin manager

Add the plugin, then call `require("ai-chat").setup({})` somewhere in your config.

## Quick Start

1. Install the plugin and call `setup()`
2. For Ollama (default): `ollama serve` and `ollama pull llama3.2`. For Anthropic: set `ANTHROPIC_API_KEY` env var.
3. Open the chat panel: `:AiChat` or `<leader>aa`
4. Type a question in the input buffer, press `<CR>` to send
5. Navigate: `]]`/`[[` between messages, `]b`/`[b` between code blocks, `gY` to yank a code block, `q` to close

Run `:checkhealth ai-chat` if something isn't working.

## Configuration

### Default Config

```lua
require("ai-chat").setup({
    -- Active provider and model
    default_provider = "ollama",
    default_model = "llama3.2",

    -- Provider-specific configuration
    providers = {
        ollama = {
            host = "http://localhost:11434",
        },
        anthropic = {
            model = "claude-sonnet-4-20250514",
            max_tokens = 16000,
            thinking_budget = 10000,
        },
        bedrock = {
            region = "us-east-1",
            model = "anthropic.claude-sonnet-4-20250514-v1:0",
        },
        openai_compat = {
            endpoint = "https://api.openai.com/v1/chat/completions",
            model = "gpt-4o",
        },
    },

    -- UI
    ui = {
        width = 0.25,          -- fraction of editor width
        min_width = 60,
        max_width = 120,
        position = "right",    -- "right" or "left"
        input_height = 3,
        input_max_height = 10,
        show_winbar = true,
        show_cost = true,
        show_tokens = true,
        spinner = true,
    },

    -- Chat behavior
    chat = {
        system_prompt = nil,   -- nil uses built-in default
        temperature = 0.7,
        max_tokens = 4096,
        thinking = false,      -- enable extended thinking (Claude)
        show_thinking = true,  -- render thinking blocks (false = fold closed)
        auto_scroll = true,
    },

    -- History / persistence
    history = {
        enabled = true,
        max_conversations = 100,
        storage_path = nil,    -- nil uses vim.fn.stdpath("data") .. "/ai-chat/history"
    },

    -- Keybindings (set any to false to disable)
    keys = {
        -- Global
        toggle = "<leader>aa",
        send_selection = "<leader>as",
        quick_explain = "<leader>ae",
        quick_fix = "<leader>af",
        focus_input = "<leader>ac",
        switch_model = "<leader>am",
        switch_provider = "<leader>ap",
        -- Chat buffer
        close = "q",
        cancel = "<C-c>",
        next_message = "]]",
        prev_message = "[[",
        next_code_block = "]b",
        prev_code_block = "[b",
        yank_code_block = "gY",
        open_code_block = "gO",
        show_help = "?",
        -- Input buffer
        submit_normal = "<CR>",
        submit_insert = "<C-CR>",
        recall_prev = "<Up>",
        recall_next = "<Down>",
    },

    -- Integrations
    integrations = {
        treesitter = true,
    },

    -- Logging
    log = {
        enabled = true,
        level = "info",
        file = nil,            -- nil uses vim.fn.stdpath("data") .. "/ai-chat/log.txt"
        max_size_mb = 10,
    },
})
```

### Runtime Changes

Config is frozen after `setup()`. Use `require("ai-chat.config").set("chat.thinking", true)` to change values at runtime. Changes to `chat.*` settings take effect on the next send.

### Per-Project Config

Drop a `.ai-chat.lua` in your project root. It runs on `setup()` and can override provider, model, and system prompt:

```lua
-- .ai-chat.lua
return {
    default_provider = "anthropic",
    default_model = "claude-sonnet-4-20250514",
    system_prompt = "You are an expert in this project's Lua codebase.",
    temperature = 0.3,
}
```

## Providers

| Provider | Key | Auth | Notes |
|---|---|---|---|
| `ollama` | Default | None | Local inference, `ollama serve` required |
| `anthropic` | — | `ANTHROPIC_API_KEY` env var | Extended thinking support |
| `bedrock` | — | AWS CLI configured | Uses `aws` CLI for auth |
| `openai_compat` | — | `OPENAI_API_KEY` env var | Works with any OpenAI-compatible API |

### Ollama

Default provider. No API key. Requires Ollama running locally.

```lua
opts = {
    default_provider = "ollama",
    default_model = "llama3.2",
    providers = { ollama = { host = "http://localhost:11434" } },
}
```

### Anthropic

```lua
opts = {
    default_provider = "anthropic",
    default_model = "claude-sonnet-4-20250514",
}
```

Set `ANTHROPIC_API_KEY` in your environment. Enable extended thinking with `chat = { thinking = true }`.

### Amazon Bedrock

```lua
opts = {
    default_provider = "bedrock",
    default_model = "anthropic.claude-sonnet-4-20250514-v1:0",
    providers = { bedrock = { region = "us-east-1" } },
}
```

Requires AWS CLI configured with appropriate permissions.

### OpenAI-Compatible

```lua
opts = {
    default_provider = "openai_compat",
    default_model = "gpt-4o",
    providers = {
        openai_compat = {
            endpoint = "https://api.openai.com/v1/chat/completions",
        },
    },
}
```

Set `OPENAI_API_KEY` in your environment. Change `endpoint` for other OpenAI-compatible services.

## Commands

| Command | Description |
|---|---|
| `:AiChat` | Toggle chat panel |
| `:AiChatOpen` | Open chat panel |
| `:AiChatClose` | Close chat panel |
| `:AiChatSend [msg]` | Send message (uses input buffer if no arg) |
| `:AiChatClear` | Clear conversation |
| `:AiChatModel [name]` | Switch model (opens picker if no arg) |
| `:AiChatProvider [name]` | Switch provider (opens picker if no arg) |
| `:AiChatHistory` | Browse conversation history |
| `:AiChatSave [name]` | Save current conversation |
| `:AiChatLog` | Open audit log |
| `:AiChatCosts` | Show session cost summary |
| `:AiChatKeys` | Show keybinding reference |
| `:AiChatConfig` | Show resolved configuration |

## Keybindings

### Global

| Key | Mode | Action |
|---|---|---|
| `<leader>aa` | n | Toggle panel |
| `<leader>as` | v | Send selection |
| `<leader>ae` | v | Explain selection |
| `<leader>af` | v | Fix selection |
| `<leader>ac` | n | Focus input |
| `<leader>am` | n | Switch model (picker) |
| `<leader>ap` | n | Switch provider (picker) |

### Chat Buffer

| Key | Action |
|---|---|
| `q` | Close panel |
| `<C-c>` | Cancel generation |
| `]]` / `[[` | Next / previous message |
| `]b` / `[b` | Next / previous code block |
| `gY` | Yank code block under cursor |
| `gO` | Open code block in split |
| `?` | Show keybinding help |

### Input Buffer

| Key | Mode | Action |
|---|---|---|
| `<CR>` | n | Submit message |
| `<C-CR>` | i | Submit message |
| `<Up>` / `<Down>` | n | Recall previous / next message |

Set any key to `false` in your config to disable it.

## Events

ai-chat.nvim fires User autocmds at key lifecycle points. Use them for statusline integration, custom workflows, or logging.

| Event | Fired When | Payload |
|---|---|---|
| `AiChatPanelOpened` | Chat panel opens | `{ winid, bufnr }` |
| `AiChatPanelClosed` | Chat panel closes | — |
| `AiChatConversationCleared` | Conversation cleared | — |
| `AiChatProviderChanged` | Provider/model switched | `{ provider, model }` |
| `AiChatResponseStart` | Response begins streaming | `{ provider, model }` |
| `AiChatResponseDone` | Response completes | `{ response, ttft_ms }` |
| `AiChatResponseError` | Response fails | `{ error }` |

### Example: Statusline Integration

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "AiChatResponseStart",
    callback = function()
        vim.g.ai_status = "⏳ Thinking..."
    end,
})

vim.api.nvim_create_autocmd("User", {
    pattern = { "AiChatResponseDone", "AiChatResponseError" },
    callback = function(event)
        vim.g.ai_status = event.match == "AiChatResponseDone" and "✓" or "✗"
    end,
})
```

See [docs/events.md](docs/events.md) for full payload documentation.

## Highlight Groups

| Group | Default Link | Used For |
|---|---|---|
| `AiChatUser` | `Title` | User message headers |
| `AiChatAssistant` | `Statement` | Assistant message headers |
| `AiChatMeta` | `Comment` | Code fences, metadata |
| `AiChatError` | `DiagnosticError` | Error messages |
| `AiChatWarning` | `DiagnosticWarn` | Warnings |
| `AiChatSpinner` | `DiagnosticInfo` | Loading spinner |
| `AiChatSeparator` | `WinSeparator` | Panel separator |
| `AiChatInputPrompt` | `Question` | Input prompt |
| `AiChatThinking` | `Comment` | Thinking block content |
| `AiChatThinkingHeader` | `DiagnosticInfo` | Thinking block headers |

All groups use `default = true` — override them in your colorscheme.

## Health Check

```
:checkhealth ai-chat
```

Checks: Neovim version, curl, provider reachability (Ollama), API keys (Anthropic, OpenAI), AWS CLI (Bedrock), treesitter markdown parser, writable history and log directories.

## Design Philosophy

The plugin treats the AI as a tool you consult, not a copilot that takes over. It never steals focus, never moves your cursor, never auto-applies generated code. All provider communication is async — the editor never blocks.

Everything is a buffer. The chat panel is a real Neovim buffer — yank, search, motions, and operators all work. The input buffer supports modal editing. No custom rendering that bypasses buffer primitives.

Transparency is non-negotiable. You can always see which model is responding, inspect costs, review the audit log, and cancel a request. The plugin never hides what it's doing.

Read the full [design principles](PRINCIPLES.md) and [architecture](docs/architecture.md).

## Contributing

```bash
make test            # Run all tests (headless Neovim)
make lint            # Check formatting (stylua)
make format          # Auto-format
make verify          # Run verification suite
```

Tests run inside headless Neovim — there is no standalone Lua runner. Read [AGENTS.md](AGENTS.md) for the full development guide.

## License

MIT
