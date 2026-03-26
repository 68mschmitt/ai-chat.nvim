--- ai-chat.nvim — Send pipeline
--- Orchestrates the full lifecycle of sending a message: slash command
--- routing, preflight checks, context collection, message building,
--- truncation notification, and provider streaming.
---
--- Extracted from init.lua to keep the coordinator focused on public API
--- and module wiring. This module owns the send logic; init.lua delegates.

local M = {}

--- State shared with the pipeline across sends.
--- Populated by init() before first use.
---@class PipelineState
local pstate = {
    preflight_done = {}, -- { [provider_name] = true } — once per session per provider
    truncation_notified = false,
}

--- Last request debug info (for /debug command).
---@class PipelineDebugInfo
---@field provider_messages AiChatMessage[]?
---@field opts table?
---@field provider string?
---@field model string?
---@field timestamp number?
---@field context AiChatContext[]?
---@field truncated number?
local last_request = {}

--- Reset pipeline state (called on conversation clear).
function M.reset()
    pstate.truncation_notified = false
    last_request = {}
end

--- Get the last request debug info (for /debug).
---@return PipelineDebugInfo
function M.get_last_request()
    return vim.deepcopy(last_request)
end

--- Execute the full send pipeline.
---
---@param text string              User message text
---@param opts table               { context?: string[], callback?: fun(response) }
---@param ui_state table           { chat_bufnr, chat_winid, input_bufnr, input_winid, is_open }
---@param deps table               Injected dependencies:
---   conversation: the conversation module
---   stream: the stream module
---   config: resolved config table
---   open_fn: function to open the panel if needed
---   update_winbar_fn: function to update the winbar
function M.send(text, opts, ui_state, deps)
    local config = deps.config
    local conv = deps.conversation
    local stream = deps.stream

    -- Ensure panel is open
    if not ui_state.is_open then
        deps.open_fn()
    end

    -- Slash commands — route and exit
    if text:match("^/") then
        require("ai-chat.commands").handle(text, {
            config = config,
            conversation = conv.get(),
        })
        if ui_state.is_open then
            require("ai-chat.ui.input").clear()
        end
        return
    end

    -- Provider preflight check (once per session per provider)
    local provider_name = conv.get_provider()
    if not pstate.preflight_done[provider_name] then
        pstate.preflight_done[provider_name] = true
        require("ai-chat.providers").preflight(
            provider_name,
            config.providers[provider_name]
        )
    end

    -- Collect and strip context
    local context_mod = require("ai-chat.context")
    local context = context_mod.collect(text, opts.context)
    local clean_text = context_mod.strip_tags(text)
    if clean_text == "" then
        clean_text = text
    end

    -- Build and append user message
    local message = {
        role = "user",
        content = clean_text,
        context = context,
        timestamp = os.time(),
    }
    conv.append(message)
    require("ai-chat.ui.render").render_message(ui_state.chat_bufnr, message)
    require("ai-chat.ui.input").clear()

    -- Build provider messages
    local provider_messages, truncated = conv.build_provider_messages(config)
    if truncated and not pstate.truncation_notified then
        pstate.truncation_notified = true
        vim.notify(
            string.format("[ai-chat] Context window: %d older messages truncated", truncated),
            vim.log.levels.INFO
        )
    end

    -- Record debug info for /debug command
    last_request = {
        provider_messages = provider_messages,
        opts = {
            model = conv.get_model(),
            provider_name = provider_name,
            temperature = config.chat.temperature,
            max_tokens = config.chat.max_tokens,
            thinking = config.chat.thinking,
        },
        provider = provider_name,
        model = conv.get_model(),
        timestamp = os.time(),
        context = context,
        truncated = truncated,
    }

    -- Start streaming
    local provider = require("ai-chat.providers").get(provider_name)
    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AiChatResponseStart",
        data = { provider = provider_name, model = conv.get_model() },
    })

    if not ui_state.is_open or not ui_state.chat_bufnr then
        return
    end

    stream.send(provider, provider_messages, {
        model = conv.get_model(),
        provider_name = provider_name,
        temperature = config.chat.temperature,
        max_tokens = config.chat.max_tokens,
        thinking = config.chat.thinking,
    }, {
        chat_bufnr = ui_state.chat_bufnr,
        chat_winid = ui_state.chat_winid,
    }, {
        on_done = function(response)
            deps.update_winbar_fn()
            conv.append({
                role = "assistant",
                content = response.content,
                usage = response.usage,
                model = response.model,
                thinking = response.thinking,
                timestamp = os.time(),
            })
            if response.usage then
                require("ai-chat.util.costs").record(provider_name, conv.get_model(), response.usage)
            end
            if config.history.enabled then
                require("ai-chat.history").save(conv.get())
            end
            pcall(vim.api.nvim_exec_autocmds, "User", {
                pattern = "AiChatResponseDone",
                data = { response = response, usage = response.usage },
            })
            if opts.callback then
                opts.callback(response)
            end
        end,
        on_error = function(err)
            require("ai-chat.util.log").error("Provider error", err)
            pcall(vim.api.nvim_exec_autocmds, "User", {
                pattern = "AiChatResponseError",
                data = { error = err },
            })
        end,
    })
end

return M
