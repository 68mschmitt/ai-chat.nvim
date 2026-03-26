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

---@class AiChatConversationState
local state = {
    id = "",
    messages = {},
    provider = "",
    model = "",
    created_at = 0,
}

--- Per-provider default context windows (in tokens).
--- Used for truncation when the conversation exceeds the model's limit.
local context_windows = {
    ollama = 4096,
    anthropic = 200000,
    bedrock = 200000,
    openai_compat = 128000,
}

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
---@param conversation AiChatConversation
function M.restore(conversation)
    state = {
        id = conversation.id or M._uuid(),
        messages = conversation.messages or {},
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
---@param message AiChatMessage
function M.append(message)
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

    -- Conversation history with inlined context
    for _, msg in ipairs(state.messages) do
        local content = msg.content
        -- Inline context above the user's message
        if msg.role == "user" and msg.context and #msg.context > 0 then
            local context_parts = {}
            for _, ctx in ipairs(msg.context) do
                table.insert(
                    context_parts,
                    string.format('<context type="%s" source="%s">\n%s\n</context>', ctx.type, ctx.source, ctx.content)
                )
            end
            content = table.concat(context_parts, "\n\n") .. "\n\n" .. content
        end
        table.insert(messages, { role = msg.role, content = content })
    end

    -- Apply context window truncation
    local max_tokens = M._get_context_window(state.provider)
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

--- Get the context window size for a provider.
---@param provider string
---@return number
function M._get_context_window(provider)
    return context_windows[provider] or 4096
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
