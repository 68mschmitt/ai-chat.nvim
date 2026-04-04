--- ai-chat.nvim — Send pipeline
--- Orchestrates the full lifecycle of sending a message: preflight checks,
--- message building, truncation notification, and provider streaming.
---
--- Extracted from init.lua to keep the coordinator focused on public API
--- and module wiring. This module owns the send logic; init.lua delegates.

local M = {}

local providers = require("ai-chat.providers")
local render = require("ai-chat.ui.render")
local spinner = require("ai-chat.ui.spinner")
local input_mod = require("ai-chat.ui.input")
local history = require("ai-chat.history")
local models = require("ai-chat.models")
local costs = require("ai-chat.util.costs")
local log = require("ai-chat.util.log")

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
---@param ui_state table           { chat_bufnr, chat_winid, input_bufnr, input_winid, is_open }
---@param deps table               Injected dependencies:
---   conversation: the conversation module
---   stream: the stream module
---   config: resolved config table
---   open_fn: function to open the panel if needed
---   update_winbar_fn: function to update the winbar
function M.send(text, ui_state, deps)
    local config = deps.config
    local conv = deps.conversation
    local stream = deps.stream

    -- GAP-21: Capture send time for TTFT measurement
    local uv = vim.uv or vim.loop
    local send_hrtime = uv.hrtime()

    -- Ensure panel is open
    if not ui_state.is_open then
        deps.open_fn()
    end

    -- Provider preflight check (once per session per provider)
    local provider_name = conv.get_provider()
    if not pstate.preflight_done[provider_name] then
        pstate.preflight_done[provider_name] = true
        providers.preflight(provider_name, config.providers[provider_name])
    end

    -- Build and append user message
    local message = {
        role = "user",
        content = text,
        timestamp = os.time(),
    }
    conv.append(message)
    render.render_message(ui_state.chat_bufnr, message)
    input_mod.clear()

    -- Build provider messages
    local provider_messages, truncated = conv.build_provider_messages(config)
    if truncated and not pstate.truncation_notified then
        pstate.truncation_notified = true
        vim.notify(
            string.format("[ai-chat] Context window: %d older messages truncated", truncated),
            vim.log.levels.INFO
        )
    end

    -- Record debug info for introspection
    last_request = {
        provider_messages = provider_messages,
        opts = {
            model = conv.get_model(),
            provider_name = provider_name,
            provider_config = config.providers[provider_name] or {},
            temperature = config.chat.temperature,
            max_tokens = config.chat.max_tokens,
            thinking = config.chat.thinking,
        },
        provider = provider_name,
        model = conv.get_model(),
        timestamp = os.time(),
        truncated = truncated,
    }

    -- Start streaming
    local provider = providers.get(provider_name)
    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AiChatResponseStart",
        data = { provider = provider_name, model = conv.get_model() },
    })

    if not ui_state.is_open or not ui_state.chat_bufnr then
        return
    end

    -- Start spinner — pipeline owns spinner lifecycle
    spinner.start(ui_state.chat_winid)

    -- Wire spinner stop to all terminal response events.
    -- One augroup per send — cleared on each new send, deleted on terminal.
    local spinner_group = vim.api.nvim_create_augroup("ai-chat-spinner", { clear = true })
    local function stop_spinner_and_cleanup()
        spinner.stop()
        pcall(vim.api.nvim_del_augroup_by_id, spinner_group)
    end
    for _, pattern in ipairs({ "AiChatResponseDone", "AiChatResponseError", "AiChatResponseCancelled" }) do
        vim.api.nvim_create_autocmd("User", {
            group = spinner_group,
            pattern = pattern,
            once = true,
            callback = function()
                stop_spinner_and_cleanup()
            end,
        })
    end

    -- Create render factory — stream calls this for each attempt (including retries)
    local begin_response = function()
        return render.begin_response(ui_state.chat_bufnr)
    end

    stream.send(
        provider,
        provider_messages,
        {
            model = conv.get_model(),
            provider_name = provider_name,
            provider_config = config.providers[provider_name] or {},
            temperature = config.chat.temperature,
            max_tokens = config.chat.max_tokens,
            thinking = config.chat.thinking,
        },
        begin_response,
        {
            on_done = function(response, ttft_ms)
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
                    local reg_pricing = models.get_pricing(provider_name, conv.get_model())
                    costs.record(provider_name, conv.get_model(), response.usage, reg_pricing)
                end
                if config.history.enabled then
                    history.save(conv.get())
                end
                pcall(vim.api.nvim_exec_autocmds, "User", {
                    pattern = "AiChatResponseDone",
                    data = { response = response, usage = response.usage, ttft_ms = ttft_ms },
                })
            end,
            on_error = function(err)
                log.error("Provider error", err)
                pcall(vim.api.nvim_exec_autocmds, "User", {
                    pattern = "AiChatResponseError",
                    data = { error = err },
                })
            end,
        },
        send_hrtime
    )
end

return M
