--- ai-chat.nvim — Stream orchestration
--- Manages the lifecycle of a streaming response: start, cancel, retry.
--- Calls providers and UI (render, spinner) but receives conversation data
--- as arguments. Calls back to the coordinator via callbacks for
--- history/costs/winbar updates.
---
--- Retry policy: only errors classified as RETRYABLE by errors.lua are
--- retried. FATAL and UNKNOWN errors fail immediately.

local M = {}

local errors = require("ai-chat.errors")
local spinner = require("ai-chat.ui.spinner")
local render = require("ai-chat.ui.render")
local log = require("ai-chat.util.log")
local models = require("ai-chat.models")
local costs = require("ai-chat.util.costs")

--- State machine transition diagram:
---   idle        --send-->          streaming
---   streaming   --done-->          idle
---   streaming   --error_retryable-->  retrying
---   streaming   --error_fatal-->   idle
---   streaming   --cancel-->        idle
---   retrying    --retry_fire-->    streaming
---   retrying    --cancel-->        idle
local TRANSITIONS = {
    idle = { send = "streaming" },
    streaming = { done = "idle", error_retryable = "retrying", error_fatal = "idle", cancel = "idle" },
    retrying = { retry_fire = "streaming", cancel = "idle" },
}

-- Load-time validation: verify all target phases exist
for phase, events in pairs(TRANSITIONS) do
    for event, target in pairs(events) do
        assert(
            TRANSITIONS[target],
            string.format("stream: transition %s + %s -> %s, but %s is not a known phase", phase, event, target, target)
        )
    end
end

--- Transition to the next phase.
---@param current_phase string
---@param event string
---@return string  The next phase
local function transition(current_phase, event)
    local targets = TRANSITIONS[current_phase]
    if not targets then
        error(string.format("[ai-chat] stream: unknown phase %q", current_phase))
    end
    local next_phase = targets[event]
    if not next_phase then
        error(string.format("[ai-chat] stream: illegal transition %s + %s", current_phase, event))
    end
    return next_phase
end

---@class AiChatStreamState
local state = { phase = "idle", generation = 0 }

--- Set the stream state.
---@param new_state table
local function set_state(new_state)
    assert(new_state.phase, "[ai-chat] stream: state must have a phase")
    state = new_state
end

--- Maximum retry attempts for transient errors.
local MAX_RETRIES = 3

--- Returns whether a response is currently being streamed.
---@return boolean
function M.is_active()
    return state.phase ~= "idle"
end

--- Cancel the active generation.
---@return boolean  true if a stream was cancelled
function M.cancel()
    if state.phase == "idle" then
        return false
    end

    local gen = state.generation + 1

    if state.phase == "retrying" then
        local timer = state.retry_timer
        transition(state.phase, "cancel")
        set_state({ phase = "idle", generation = gen })
        timer:stop()
        timer:close()
    elseif state.phase == "streaming" then
        local fn = state.cancel_fn
        transition(state.phase, "cancel")
        set_state({ phase = "idle", generation = gen })
        fn()
    end

    spinner.stop()
    return true
end

--- Send a chat request with streaming. Handles the full lifecycle:
--- spinner start, provider call, chunk rendering, completion, error/retry.
---
---@param provider AiChatProvider  The provider module to call
---@param provider_messages AiChatMessage[]  Messages to send (already built)
---@param opts AiChatProviderOpts  Provider options (model, temperature, etc.)
---@param ui_state { chat_bufnr: number, chat_winid: number }  UI references
---@param callbacks { on_done: fun(response: AiChatResponse, ttft_ms: number?), on_error: fun(err: AiChatError) }
---@param send_hrtime number?  High-resolution time when send started (for TTFT measurement)
function M.send(provider, provider_messages, opts, ui_state, callbacks, send_hrtime)
    if state.phase ~= "idle" then
        vim.notify("[ai-chat] Already generating a response. Press <C-c> to cancel.", vim.log.levels.WARN)
        return
    end

    transition(state.phase, "send")
    set_state({ phase = "streaming", generation = state.generation + 1, cancel_fn = function() end })

    M._do_send(provider, provider_messages, opts, ui_state, callbacks, send_hrtime)
end

--- Internal: perform the actual send (called directly and on retry).
---@param provider AiChatProvider
---@param provider_messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param ui_state { chat_bufnr: number, chat_winid: number }
---@param callbacks { on_done: fun(response: AiChatResponse, ttft_ms: number?), on_error: fun(err: AiChatError) }
---@param send_hrtime number?  High-resolution time when send started (for TTFT measurement)
function M._do_send(provider, provider_messages, opts, ui_state, callbacks, send_hrtime)
    local gen = state.generation
    spinner.start(ui_state.chat_winid)

    -- Create stream renderer
    local stream_render = render.begin_response(ui_state.chat_bufnr)

    -- Guard callbacks: enforce (on_chunk* · (on_done | on_error)) cardinality.
    -- After the first terminal callback (on_done or on_error), all further
    -- callbacks are silenced. The generation counter also silences callbacks
    -- from a cancelled or superseded send.
    local terminal_fired = false
    local first_chunk = true

    local guarded = {
        on_chunk = function(chunk_text)
            if terminal_fired or gen ~= state.generation then
                return
            end

            -- GAP-21: TTFT measurement on first chunk
            if first_chunk and send_hrtime then
                first_chunk = false
                local uv = vim.uv or vim.loop
                local ttft_ms = (uv.hrtime() - send_hrtime) / 1e6
                log.info(string.format("TTFT: %.0fms", ttft_ms))
                state.ttft_ms = ttft_ms -- save for on_done
            else
                first_chunk = false
            end

            stream_render.append(chunk_text)
        end,

        on_done = function(response)
            if terminal_fired or gen ~= state.generation then
                return
            end
            terminal_fired = true

            local ttft = state.ttft_ms
            transition(state.phase, "done")
            set_state({ phase = "idle", generation = gen })
            spinner.stop()

            -- GAP-08: Pre-compute cost display for render
            local cost_display = nil
            if response.usage then
                local reg_pricing = models.get_pricing(opts.provider_name, opts.model)
                cost_display = costs.estimate(opts.provider_name, opts.model, response.usage, reg_pricing)
                if cost_display > 0 then
                    cost_display = string.format("$%.4f", cost_display)
                else
                    cost_display = nil
                end
            end

            -- Finalize rendering with pre-computed cost display
            stream_render.finish(response.usage, cost_display)

            -- Notify coordinator with TTFT
            callbacks.on_done(response, ttft)
        end,

        on_error = function(err)
            if terminal_fired or gen ~= state.generation then
                return
            end
            terminal_fired = true

            spinner.stop()

            -- Check if we should auto-retry (centralized classification)
            if errors.is_retryable(err) and state.phase == "streaming" then
                -- Count retries (stored on state for retrying phase)
                local retry_count = (state.retry_count or 0) + 1
                if retry_count <= MAX_RETRIES then
                    local delay = M._backoff_delay(retry_count)

                    stream_render.error({
                        code = err.code,
                        message = string.format(
                            "%s (retrying in %ds, attempt %d/%d)",
                            err.message,
                            delay,
                            retry_count,
                            MAX_RETRIES
                        ),
                        retryable = true,
                    })

                    local uv = vim.uv or vim.loop
                    local timer = uv.new_timer()

                    transition(state.phase, "error_retryable")
                    set_state({
                        phase = "retrying",
                        generation = gen,
                        retry_count = retry_count,
                        retry_timer = timer,
                    })

                    timer:start(
                        delay * 1000,
                        0,
                        vim.schedule_wrap(function()
                            if state.phase == "retrying" and state.retry_timer == timer then
                                timer:stop()
                                timer:close()
                                transition(state.phase, "retry_fire")
                                set_state({
                                    phase = "streaming",
                                    generation = gen,
                                    cancel_fn = function() end,
                                    retry_count = retry_count,
                                })
                                M._do_send(provider, provider_messages, opts, ui_state, callbacks, send_hrtime)
                            end
                        end)
                    )
                    return
                end
            end

            -- Fatal error or max retries exceeded
            transition(state.phase, "error_fatal")
            set_state({ phase = "idle", generation = gen })

            stream_render.error(err)
            callbacks.on_error(err)
        end,
    }

    local cancel_fn = provider.chat(provider_messages, opts, guarded)
    -- Update cancel_fn on state (we're in streaming phase)
    state.cancel_fn = cancel_fn
end

--- Calculate exponential backoff delay.
---@param attempt number  Current attempt (1-indexed)
---@return number  Delay in seconds
function M._backoff_delay(attempt)
    -- 2s, 4s, 8s
    return math.min(2 ^ attempt, 8)
end

return M
