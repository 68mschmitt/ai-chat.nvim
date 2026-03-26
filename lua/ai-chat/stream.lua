--- ai-chat.nvim — Stream orchestration
--- Manages the lifecycle of a streaming response: start, cancel, retry.
--- Calls providers and UI (render, spinner) but receives conversation data
--- as arguments. Calls back to the coordinator via callbacks for
--- history/costs/winbar updates.

local M = {}

---@class AiChatStreamState
local state = {
    active = false,
    cancel_fn = nil,
    retry_count = 0,
    retry_timer = nil,
}

--- Maximum retry attempts for transient errors.
local MAX_RETRIES = 3

--- Returns whether a response is currently being streamed.
---@return boolean
function M.is_active()
    return state.active
end

--- Cancel the active generation.
---@return boolean  true if a stream was cancelled
function M.cancel()
    if state.retry_timer then
        state.retry_timer:stop()
        state.retry_timer:close()
        state.retry_timer = nil
    end
    if state.active and state.cancel_fn then
        state.cancel_fn()
        state.active = false
        state.cancel_fn = nil
        state.retry_count = 0
        require("ai-chat.ui.spinner").stop()
        return true
    end
    return false
end

--- Send a chat request with streaming. Handles the full lifecycle:
--- spinner start, provider call, chunk rendering, completion, error/retry.
---
---@param provider AiChatProvider  The provider module to call
---@param provider_messages AiChatMessage[]  Messages to send (already built)
---@param opts AiChatProviderOpts  Provider options (model, temperature, etc.)
---@param ui_state { chat_bufnr: number, chat_winid: number }  UI references
---@param callbacks { on_done: fun(response: AiChatResponse), on_error: fun(err: AiChatError) }
function M.send(provider, provider_messages, opts, ui_state, callbacks)
    if state.active then
        vim.notify("[ai-chat] Already generating a response. Press <C-c> to cancel.", vim.log.levels.WARN)
        return
    end

    state.active = true
    state.retry_count = 0

    M._do_send(provider, provider_messages, opts, ui_state, callbacks)
end

--- Internal: perform the actual send (called directly and on retry).
---@param provider AiChatProvider
---@param provider_messages AiChatMessage[]
---@param opts AiChatProviderOpts
---@param ui_state { chat_bufnr: number, chat_winid: number }
---@param callbacks { on_done: fun(response: AiChatResponse), on_error: fun(err: AiChatError) }
function M._do_send(provider, provider_messages, opts, ui_state, callbacks)
    local spinner = require("ai-chat.ui.spinner")
    local render = require("ai-chat.ui.render")

    spinner.start(ui_state.chat_winid)

    -- Create stream renderer
    local stream_render = render.begin_response(ui_state.chat_bufnr)

    state.cancel_fn = provider.chat(
        provider_messages,
        opts,
        {
            on_chunk = function(chunk_text)
                stream_render.append(chunk_text)
            end,

            on_done = function(response)
                state.active = false
                state.cancel_fn = nil
                state.retry_count = 0
                spinner.stop()

                -- Finalize rendering with actual provider/model for cost calculation
                stream_render.finish(response.usage, {
                    provider = opts.provider_name,
                    model = opts.model,
                })

                -- Notify coordinator
                callbacks.on_done(response)
            end,

            on_error = function(err)
                spinner.stop()

                -- Check if we should auto-retry
                if err.retryable and state.retry_count < MAX_RETRIES then
                    state.retry_count = state.retry_count + 1
                    local delay = M._backoff_delay(state.retry_count)

                    -- Show retry message in the stream render
                    stream_render.error({
                        code = err.code,
                        message = string.format(
                            "%s (retrying in %ds, attempt %d/%d)",
                            err.message, delay, state.retry_count, MAX_RETRIES
                        ),
                        retryable = true,
                    })

                    -- Schedule retry
                    local uv = vim.uv or vim.loop
                    state.retry_timer = uv.new_timer()
                    state.retry_timer:start(delay * 1000, 0, vim.schedule_wrap(function()
                        if state.retry_timer then
                            state.retry_timer:stop()
                            state.retry_timer:close()
                            state.retry_timer = nil
                        end
                        if state.active then
                            M._do_send(provider, provider_messages, opts, ui_state, callbacks)
                        end
                    end))
                else
                    -- Final failure
                    state.active = false
                    state.cancel_fn = nil
                    state.retry_count = 0

                    stream_render.error(err)
                    callbacks.on_error(err)
                end
            end,
        }
    )
end

--- Calculate exponential backoff delay.
---@param attempt number  Current attempt (1-indexed)
---@return number  Delay in seconds
function M._backoff_delay(attempt)
    -- 2s, 4s, 8s
    return math.min(2 ^ attempt, 8)
end

return M
