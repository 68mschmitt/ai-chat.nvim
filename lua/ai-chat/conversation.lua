--- ai-chat.nvim — Conversation state management
--- Owns conversation lifecycle: creation, message building, system prompt,
--- and context window truncation. Pure data — never calls ui or providers.

local M = {}

---@class AiChatConversation
---@field id string
---@field messages AiChatMessage[]
---@field provider string
---@field model string
---@field created_at number

---@class AiChatMessage
---@field role string "user" or "assistant"
---@field content string
---@field timestamp? number
---@field usage? table
---@field model? string
---@field thinking? string

---@class AiChatConversationState
local state = {
    id = "",
    messages = {},
    provider = "",
    model = "",
    created_at = 0,
}

--- Per-provider default context windows (in tokens).
--- Used as fallback when a model-specific window is not defined.
local provider_context_windows = {
    ollama = 4096,
    anthropic = 200000,
    bedrock = 200000,
    openai_compat = 128000,
}

--- Per-model context windows (in tokens).
--- Takes priority over the provider default. Keyed by model name.
local model_context_windows = {
    -- Anthropic
    ["claude-sonnet-4-20250514"] = 200000,
    ["claude-opus-4-20250514"] = 200000,
    ["claude-3-5-haiku-20241022"] = 200000,
    -- Bedrock (same models, different IDs)
    ["anthropic.claude-sonnet-4-20250514-v1:0"] = 200000,
    ["anthropic.claude-opus-4-20250514-v1:0"] = 200000,
    ["anthropic.claude-3-5-haiku-20241022-v1:0"] = 200000,
    -- OpenAI
    ["gpt-4o"] = 128000,
    ["gpt-4o-mini"] = 128000,
    ["gpt-4-turbo"] = 128000,
    -- Ollama common models
    ["llama3.2"] = 4096,
    ["llama3.1"] = 128000,
    ["codellama"] = 16384,
    ["mistral"] = 32768,
    ["mixtral"] = 32768,
    ["deepseek-coder"] = 16384,
    ["phi3"] = 4096,
}

--- Valid roles for conversation messages.
local valid_roles = { user = true, assistant = true }

--- Validate a message structurally.
--- Returns true on success, false + reason string on failure.
---@param message any
---@return boolean ok
---@return string? reason
local function validate_message(message)
    if type(message) ~= "table" then
        return false, ("message must be a table, got: %s"):format(type(message))
    end
    if type(message.role) ~= "string" or message.role == "" then
        return false, ("role must be a non-empty string, got: %s"):format(vim.inspect(message.role))
    end
    if not valid_roles[message.role] then
        return false, ("role must be 'user' or 'assistant', got: %q"):format(message.role)
    end
    if type(message.content) ~= "string" then
        return false, ("content must be a string, got: %s"):format(type(message.content))
    end
    return true
end

--- Create a new conversation with the given provider and model.
---@param provider string
---@param model string
---@return AiChatConversation
function M.new(provider, model)
    state = {
        id = M._uuid(),
        messages = {},
        provider = provider,
        model = model,
        created_at = os.time(),
    }
    return M.get()
end

--- Restore a conversation from a loaded table (e.g., from history).
--- Uses lenient validation: invalid messages are skipped with warnings, valid ones are kept.
---@param conversation AiChatConversation
function M.restore(conversation)
    local log = require("ai-chat.util.log")
    local raw_messages = conversation.messages or {}
    local valid_messages = {}
    local skipped = 0

    for i, msg in ipairs(raw_messages) do
        local ok, reason = validate_message(msg)
        if ok then
            table.insert(valid_messages, msg)
        else
            skipped = skipped + 1
            log.warn(("conversation.restore: skipping message %d: %s"):format(i, reason))
        end
    end

    if skipped > 0 then
        log.warn(("conversation.restore: restored %d of %d messages (%d skipped)"):format(
            #valid_messages, #raw_messages, skipped
        ))
    end

    state = {
        id = conversation.id or M._uuid(),
        messages = valid_messages,
        provider = conversation.provider or "",
        model = conversation.model or "",
        created_at = conversation.created_at or os.time(),
    }
end

--- Get a read-only copy of the current conversation state.
---@return AiChatConversation
function M.get()
    return vim.deepcopy(state)
end

--- Append a message to the conversation history.
--- Validates structural invariants and raises error() on invalid input.
---@param message AiChatMessage
function M.append(message)
    local ok, reason = validate_message(message)
    if not ok then
        error(("[ai-chat] conversation.append: %s"):format(reason), 2)
    end
    if message.role == "user" and message.content == "" then
        error("[ai-chat] conversation.append: user message content must be non-empty", 2)
    end
    table.insert(state.messages, message)
end

--- Get the number of messages in the conversation.
---@return number
function M.message_count()
    return #state.messages
end

--- Set the active provider.
---@param provider string
function M.set_provider(provider)
    state.provider = provider
end

--- Set the active model.
---@param model string
function M.set_model(model)
    state.model = model
end

--- Get the active provider name.
---@return string
function M.get_provider()
    return state.provider
end

--- Get the active model name.
---@return string
function M.get_model()
    return state.model
end

--- Build the message array to send to the provider.
--- Includes system prompt, conversation history with inlined context,
--- and applies context window truncation if needed.
---@param config AiChatConfig
---@return AiChatMessage[] messages  Messages to send
---@return number? truncated_count  Number of messages dropped (nil if no truncation)
function M.build_provider_messages(config)
    local messages = {}

    -- System prompt
    local system_prompt = config.chat.system_prompt or M._default_system_prompt()
    table.insert(messages, { role = "system", content = system_prompt })

    -- Conversation history
    for _, msg in ipairs(state.messages) do
        table.insert(messages, { role = msg.role, content = msg.content })
    end

    -- Apply context window truncation (per-model, with provider fallback)
    local max_tokens = M._get_context_window(state.provider, state.model, config)
    local truncated = M._truncate_to_budget(messages, max_tokens)

    return messages, truncated
end

--- Default system prompt.
---@return string
function M._default_system_prompt()
    return table.concat({
        "You are a helpful coding assistant embedded in a neovim editor.",
        "The user will ask questions about their code and you should provide",
        "clear, concise answers. When suggesting code changes, use fenced code",
        "blocks with the appropriate language identifier.",
        "Be direct. Avoid unnecessary preamble.",
    }, " ")
end

--- Get the context window size for a model, with provider-level fallback.
--- All external data is received via arguments — no internal requires.
---@param provider string
---@param model string
---@param config table  Resolved plugin config (passed by coordinator)
---@return number
function M._get_context_window(provider, model, config)
    -- 1. Check hardcoded per-model table
    if model and model_context_windows[model] then
        return model_context_windows[model]
    end
    -- 2. Check user config override (allows configuring custom models)
    if config and config.providers and config.providers[provider] then
        local provider_cfg = config.providers[provider]
        if provider_cfg.context_window then
            return provider_cfg.context_window
        end
    end
    -- 3. Fall back to provider default
    return provider_context_windows[provider] or 4096
end

--- Truncate messages to fit within a token budget.
--- Strategy: Remove oldest messages first, always preserve the system prompt
--- (index 1) and the most recent user message (last).
---@param messages AiChatMessage[]  The full message array (mutated in place)
---@param max_tokens number  Maximum token budget
---@return number?  Number of messages dropped, or nil if no truncation
function M._truncate_to_budget(messages, max_tokens)
    local tokens = require("ai-chat.util.tokens")

    -- Estimate total tokens
    local total = 0
    for _, msg in ipairs(messages) do
        total = total + tokens.estimate(msg.content)
    end

    if total <= max_tokens then
        return nil -- No truncation needed
    end

    -- Remove messages from index 2 (after system prompt) until we're under budget.
    -- Always preserve index 1 (system prompt) and the last message (most recent).
    local dropped = 0
    while total > max_tokens and #messages > 2 do
        local removed = table.remove(messages, 2)
        total = total - tokens.estimate(removed.content)
        dropped = dropped + 1
    end

    return dropped > 0 and dropped or nil
end

--- Generate a UUID v4.
---@return string
function M._uuid()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format("%x", v)
    end)
end

return M
