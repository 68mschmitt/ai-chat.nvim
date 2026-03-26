--- ai-chat.nvim — Cost estimation and tracking
--- Estimates API costs per provider/model and tracks cumulative spending.

local M = {}

-- Cost per 1M tokens (input / output) — updated periodically
-- Source: provider pricing pages. These are approximate.
local pricing = {
    anthropic = {
        ["claude-sonnet-4-20250514"]     = { input = 3.00,  output = 15.00 },
        ["claude-opus-4-20250514"]      = { input = 15.00, output = 75.00 },
        ["claude-3-5-haiku-20241022"]    = { input = 1.00,  output = 5.00 },
    },
    openai_compat = {
        ["gpt-4o"]                       = { input = 2.50,  output = 10.00 },
        ["gpt-4o-mini"]                  = { input = 0.15,  output = 0.60 },
        ["gpt-4-turbo"]                  = { input = 10.00, output = 30.00 },
    },
    -- Ollama and Bedrock: cost handled separately
    ollama = {},  -- Always $0.00
    bedrock = {}, -- Same as Anthropic pricing (approximately)
}

-- Cumulative cost tracking (in-memory, persisted on save)
local totals = {
    session = 0,
    session_requests = 0,
}

--- Estimate cost for a single request.
---@param provider string
---@param model string
---@param usage AiChatUsage
---@return number  Estimated cost in USD
function M.estimate(provider, model, usage)
    if provider == "ollama" then return 0 end

    local provider_pricing = pricing[provider]
    if not provider_pricing then return 0 end

    local model_pricing = provider_pricing[model]
    if not model_pricing then return 0 end

    local input_cost = (usage.input_tokens / 1000000) * model_pricing.input
    local output_cost = (usage.output_tokens / 1000000) * model_pricing.output

    return input_cost + output_cost
end

--- Record a completed request for cost tracking.
---@param provider string
---@param model string
---@param usage AiChatUsage
function M.record(provider, model, usage)
    local cost = M.estimate(provider, model, usage)
    totals.session = totals.session + cost
    totals.session_requests = totals.session_requests + 1
end

--- Show cost summary.
function M.show()
    local lines = {
        "ai-chat.nvim — Cost Summary",
        "",
        string.format("  Session:  $%.4f (%d requests)", totals.session, totals.session_requests),
        "",
        "Note: Costs are estimates based on published pricing.",
        "Ollama (local) requests are always $0.00.",
    }

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Get session cost.
---@return number
function M.get_session_cost()
    return totals.session
end

return M
