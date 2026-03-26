--- Tests for ai-chat.util.costs — Cost estimation and tracking
local costs = require("ai-chat.util.costs")

describe("costs.estimate", function()
    it("returns 0 for ollama (always free)", function()
        local cost = costs.estimate("ollama", "llama3.2", {
            input_tokens = 1000,
            output_tokens = 2000,
        })
        assert.equals(0, cost)
    end)

    it("returns 0 for unknown provider", function()
        local cost = costs.estimate("nonexistent", "model", {
            input_tokens = 1000,
            output_tokens = 2000,
        })
        assert.equals(0, cost)
    end)

    it("returns 0 for unknown model in known provider", function()
        local cost = costs.estimate("anthropic", "unknown-model", {
            input_tokens = 1000,
            output_tokens = 2000,
        })
        assert.equals(0, cost)
    end)

    it("calculates cost for anthropic claude-sonnet-4", function()
        local cost = costs.estimate("anthropic", "claude-sonnet-4-20250514", {
            input_tokens = 1000000, -- 1M input
            output_tokens = 1000000, -- 1M output
        })
        -- Sonnet pricing: $3/M input, $15/M output = $18
        assert.equals(18.0, cost)
    end)

    it("calculates cost for openai gpt-4o", function()
        local cost = costs.estimate("openai_compat", "gpt-4o", {
            input_tokens = 1000000,
            output_tokens = 1000000,
        })
        -- GPT-4o pricing: $2.50/M input, $10/M output = $12.50
        assert.equals(12.5, cost)
    end)

    it("calculates small costs correctly", function()
        local cost = costs.estimate("anthropic", "claude-sonnet-4-20250514", {
            input_tokens = 100,
            output_tokens = 200,
        })
        -- 100/1M * $3 + 200/1M * $15 = $0.0003 + $0.003 = $0.0033
        assert.is_true(cost > 0, "small usage should still have cost")
        assert.is_true(cost < 0.01, "small usage should be tiny, got: " .. cost)
    end)
end)

describe("costs.record and get_session_cost", function()
    it("tracks session cost accumulation", function()
        -- Note: session state carries across tests in the same run
        local before = costs.get_session_cost()

        costs.record("anthropic", "claude-sonnet-4-20250514", {
            input_tokens = 1000,
            output_tokens = 500,
        })

        local after = costs.get_session_cost()
        assert.is_true(after > before, "session cost should increase after record")
    end)
end)
