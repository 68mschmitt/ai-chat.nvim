# ai-chat.nvim

A transparent, native-feeling AI chat interface for Neovim.

![CI](https://github.com/your-username/ai-chat.nvim/actions/workflows/ci.yml/badge.svg)

## What it does

Opens a vertical split chat panel where you can have multi-turn conversations
with AI models while keeping your code visible alongside. Pure Lua, no external
binaries beyond curl.

## Design principles

- **Transparency** — always see what context the AI receives and what it costs
- **Native** — uses splits, buffers, and standard neovim keybindings
- **Minimal** — does one thing well: chat with an AI about your code
- **Local-first** — defaults to Ollama (free, private, zero-config)

## Requirements

- Neovim >= 0.10
- curl
- An AI provider:
  - [Ollama](https://ollama.ai) (recommended) — local, free, private
  - Anthropic API key (Claude models)
  - OpenAI API key (or compatible endpoint)
  - AWS credentials (Amazon Bedrock)

## Installation

### lazy.nvim

```lua
{
    "your-username/ai-chat.nvim",
    cmd = { "AiChat", "AiChatOpen", "AiChatSend" },
    keys = { "<leader>aa", "<leader>ac" },
    config = function()
        require("ai-chat").setup({
            -- All defaults work out of the box with Ollama
        })
    end,
}
```

### Minimal setup

```lua
require("ai-chat").setup()
```

## Usage

| Command | Description |
|---------|-------------|
| `:AiChat` | Toggle the chat panel |
| `:AiChatSend [text]` | Send a message |
| `:AiChatModel [name]` | Switch model |
| `:AiChatProvider [name]` | Switch provider |
| `:AiChatHistory` | Browse saved conversations |
| `:AiChatClear` | Clear conversation |
| `:AiChatKeys` | Show all keybindings |
| `:AiChatConfig` | Show resolved configuration |
| `:AiChatCosts` | Show session cost summary |

### Context references

Add context to your messages with `@` tags:

```
@buffer How do I fix the type error on line 42?
@selection Explain this function
@diagnostics What's causing these warnings?
@diff Review my changes
@file:src/main.rs What does this module do?
```

### Key bindings

| Key | Mode | Description |
|-----|------|-------------|
| `<leader>aa` | n | Toggle chat panel |
| `<leader>as` | v | Send selection to chat |
| `<leader>ae` | v | Explain selection |
| `<leader>af` | v | Fix selection |
| `<leader>ac` | n | Focus chat input |
| `<leader>am` | n | Switch model |
| `<leader>ap` | n | Switch provider |
| `]]` / `[[` | n (chat) | Jump between messages |
| `]b` / `[b` | n (chat) | Jump between code blocks |
| `gY` | n (chat) | Yank code block |
| `ga` | n (chat) | Apply code block via diff |
| `gO` | n (chat) | Open code block in split |
| `q` | n (chat) | Close panel |
| `<C-c>` | n (chat) | Cancel generation |

All keys are configurable. Set any key to `false` to disable it.

### Providers

**Ollama** (default): Install from [ollama.ai](https://ollama.ai), run
`ollama serve`, pull a model with `ollama pull llama3.2`.

**Anthropic**: Set `ANTHROPIC_API_KEY` environment variable.

**OpenAI-compatible**: Set `OPENAI_API_KEY` environment variable. Works with
OpenAI, Azure OpenAI, Groq, Together, LM Studio.

**Amazon Bedrock**: Configure AWS CLI with appropriate credentials.

## Configuration

See `:help ai-chat-configuration` for the full configuration reference, or run
`:AiChatConfig` to see your resolved configuration.

## Health check

Run `:checkhealth ai-chat` to verify your setup.

## License

MIT
