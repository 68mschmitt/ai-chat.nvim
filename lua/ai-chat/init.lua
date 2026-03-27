--- ai-chat.nvim — Main module
--- Public API and module coordinator.
--- All user-facing functions live here. Internal modules are accessed
--- through this coordinator, never directly by the user.
---
--- State ownership:
---   config       → owned by config.lua (resolved state lives there)
---   conversation → owned by conversation.lua
---   streaming    → owned by stream.lua
---   ui refs      → owned here (chat_bufnr, chat_winid, etc.)

local M = {}

---@class AiChatState
local state = {
    ui = {
        chat_bufnr = nil,
        chat_winid = nil,
        input_bufnr = nil,
        input_winid = nil,
        is_open = false,
    },
    last_code_bufnr = nil,
}

local initialized = false

-- Lazy module references (populated on first use)
local conversation -- ai-chat.conversation
local stream -- ai-chat.stream
local pipeline -- ai-chat.pipeline

local function get_conversation()
    if not conversation then
        conversation = require("ai-chat.conversation")
    end
    return conversation
end

local function get_stream()
    if not stream then
        stream = require("ai-chat.stream")
    end
    return stream
end

local function get_pipeline()
    if not pipeline then
        pipeline = require("ai-chat.pipeline")
    end
    return pipeline
end

-- ─── Setup ───────────────────────────────────────────────────────────

--- Initialize the plugin. Must be called once in the user's config.
---@param opts? table  User configuration (merged with defaults)
function M.setup(opts)
    local config = require("ai-chat.config")
    local resolved = config.resolve(opts or {})

    local ok, err = config.validate(resolved)
    if not ok then
        vim.notify("[ai-chat] Configuration error: " .. err, vim.log.levels.ERROR)
        return
    end

    require("ai-chat.highlights").setup()
    math.randomseed(os.time() + (vim.uv or vim.loop).hrtime())
    require("ai-chat.keymaps").setup(resolved.keys)

    -- Load per-project config (.ai-chat.lua in cwd) — applies allowed overrides
    config.load_project_config()

    if resolved.history.enabled then
        require("ai-chat.history").init(resolved.history)
    end

    require("ai-chat.util.log").init(resolved.log)

    -- Initialize model registry (loads from disk cache, kicks off async refresh)
    require("ai-chat.models").init()
    M._setup_code_buffer_tracking()
    get_conversation().new(resolved.default_provider, resolved.default_model)

    initialized = true
end

-- ─── Panel ───────────────────────────────────────────────────────────

--- Toggle the chat panel open/closed.
function M.toggle()
    M._ensure_init()
    if state.ui.is_open then
        M.close()
    else
        M.open()
    end
end

--- Open the chat panel.
function M.open()
    M._ensure_init()
    if state.ui.is_open then
        return
    end

    local config = require("ai-chat.config").get()
    local result = require("ai-chat.ui").open(config.ui, get_conversation().get())
    state.ui.chat_bufnr = result.chat_bufnr
    state.ui.chat_winid = result.chat_winid
    state.ui.input_bufnr = result.input_bufnr
    state.ui.input_winid = result.input_winid
    state.ui.is_open = true

    require("ai-chat.lifecycle").setup(state.ui, get_stream)

    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AiChatPanelOpened",
        data = { winid = state.ui.chat_winid, bufnr = state.ui.chat_bufnr },
    })
end

--- Close the chat panel.
function M.close()
    if not state.ui.is_open then
        return
    end
    if get_stream().is_active() then
        M.cancel()
    end
    pcall(vim.api.nvim_del_augroup_by_name, "ai-chat-lifecycle")
    require("ai-chat.ui").close()
    state.ui.is_open = false
    state.ui.chat_winid = nil
    state.ui.input_winid = nil
    state.ui.chat_bufnr = nil
    state.ui.input_bufnr = nil
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatPanelClosed" })
end

--- Returns whether the chat panel is currently open.
---@return boolean
function M.is_open()
    return state.ui.is_open
end

-- ─── Messaging ───────────────────────────────────────────────────────

--- Send a message to the AI. Delegates orchestration to pipeline.lua.
---@param text? string  Message text. If nil, uses current input buffer content.
---@param opts? { context?: string[], callback?: fun(response: AiChatResponse) }
function M.send(text, opts)
    M._ensure_init()
    opts = opts or {}
    local config = require("ai-chat.config").get()

    if not text then
        text = require("ai-chat.ui.input").get_text()
    end
    if not text or text == "" then
        return
    end

    get_pipeline().send(text, opts, state.ui, {
        conversation = get_conversation(),
        stream = get_stream(),
        config = config,
        open_fn = function()
            M.open()
        end,
        update_winbar_fn = function()
            M._update_winbar()
        end,
    })
end

--- Cancel the active generation.
function M.cancel()
    get_stream().cancel()
end

--- Returns whether a response is currently being streamed.
---@return boolean
function M.is_streaming()
    return get_stream().is_active()
end

-- ─── Conversation ────────────────────────────────────────────────────

--- Clear the current conversation and start fresh.
function M.clear()
    M._ensure_init()
    local config = require("ai-chat.config").get()
    if get_stream().is_active() then
        M.cancel()
    end
    get_conversation().new(config.default_provider, config.default_model)
    get_pipeline().reset()
    if state.ui.is_open then
        require("ai-chat.ui.render").clear(state.ui.chat_bufnr)
        M._update_winbar()
    end
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "AiChatConversationCleared" })
end

--- Get a read-only copy of the current conversation.
---@return AiChatConversation
function M.get_conversation()
    return get_conversation().get()
end

--- Get the resolved configuration (read-only copy).
---@return AiChatConfig
function M.get_config()
    return vim.deepcopy(require("ai-chat.config").get())
end

--- Get the last known code buffer number.
---@return number?
function M.get_last_code_bufnr()
    if state.last_code_bufnr and vim.api.nvim_buf_is_valid(state.last_code_bufnr) then
        return state.last_code_bufnr
    end
    return nil
end

-- ─── Model / Provider ────────────────────────────────────────────────

--- Switch the active model.
---@param model_name? string  If nil, opens a picker.
function M.set_model(model_name)
    M._ensure_init()
    local conv = get_conversation()
    if model_name then
        conv.set_model(model_name)
        M._update_winbar()
        vim.notify("[ai-chat] Model: " .. model_name, vim.log.levels.INFO)
    else
        local config = require("ai-chat.config").get()
        local provider_name = conv.get_provider()
        local registry = require("ai-chat.models")
        local picker_items = registry.get_picker_items(provider_name)

        if #picker_items > 0 then
            -- Rich picker with display names, context windows, and pricing
            local display_list = {}
            for _, item in ipairs(picker_items) do
                table.insert(display_list, item.display)
            end
            vim.ui.select(display_list, { prompt = "Select model:" }, function(_, idx)
                if idx then
                    M.set_model(picker_items[idx].id)
                end
            end)
        else
            -- Fallback to provider's own list_models (e.g., Ollama local, OpenAI API)
            local provider = require("ai-chat.providers").get(provider_name)
            provider.list_models(config.providers[provider_name] or {}, function(models)
                if #models == 0 then
                    vim.notify("[ai-chat] No models available from " .. provider_name, vim.log.levels.WARN)
                    return
                end
                vim.ui.select(models, { prompt = "Select model:" }, function(choice)
                    if choice then
                        M.set_model(choice)
                    end
                end)
            end)
        end
    end
end

--- Switch the active provider.
---@param provider_name? string  If nil, opens a picker.
function M.set_provider(provider_name)
    M._ensure_init()
    local conv = get_conversation()
    if provider_name then
        local providers = require("ai-chat.providers")
        if not providers.exists(provider_name) then
            vim.notify("[ai-chat] Unknown provider: " .. provider_name, vim.log.levels.WARN)
            return
        end
        conv.set_provider(provider_name)
        local config = require("ai-chat.config").get()
        local provider_config = config.providers[provider_name]
        if provider_config and provider_config.model then
            conv.set_model(provider_config.model)
        end
        M._update_winbar()
        vim.notify("[ai-chat] Provider: " .. provider_name, vim.log.levels.INFO)
        pcall(vim.api.nvim_exec_autocmds, "User", {
            pattern = "AiChatProviderChanged",
            data = { provider = provider_name, model = conv.get_model() },
        })
    else
        local available = require("ai-chat.providers").list()
        vim.ui.select(available, { prompt = "Select provider:" }, function(choice)
            if choice then
                M.set_provider(choice)
            end
        end)
    end
end

--- Set thinking mode on or off.
---@param enabled boolean
function M.set_thinking(enabled)
    M._ensure_init()
    require("ai-chat.config").set("chat.thinking", enabled)
    vim.notify("[ai-chat] Thinking mode: " .. (enabled and "ON" or "OFF"), vim.log.levels.INFO)
    M._update_winbar()
end

-- ─── Proposals ───────────────────────────────────────────────────────

--- Handle proposals extracted from a /propose response.
--- Parses the response, creates proposals, places signs, and notifies the user.
---@param response_content string The AI response text
function M.handle_proposals(response_content)
    M._ensure_init()
    local parser = require("ai-chat.proposals.parse")
    local proposals = require("ai-chat.proposals")
    local ui_proposals = require("ai-chat.ui.proposals")
    local conv = get_conversation()

    local result = parser.parse(response_content, conv.get().id or "")

    -- Handle zero-proposals case
    if #result.proposals == 0 then
        if #result.warnings > 0 then
            vim.notify("[ai-chat] No proposals found -- " .. result.warnings[1], vim.log.levels.WARN)
        else
            vim.notify(
                "[ai-chat] No proposals found in response -- code blocks may be missing file annotations",
                vim.log.levels.WARN
            )
        end
        return
    end

    -- Add proposals to the data model
    for _, p in ipairs(result.proposals) do
        proposals.add(p)
    end

    -- Set up the on_expire callback for conflict detection
    local function on_expire(proposal)
        if proposal.bufnr and vim.api.nvim_buf_is_valid(proposal.bufnr) then
            ui_proposals.expire_sign(proposal.bufnr, proposal)
        end
        pcall(vim.api.nvim_exec_autocmds, "User", {
            pattern = "AiChatProposalExpired",
            data = { id = proposal.id, file = proposal.file },
        })
    end

    -- Set up buffer-local keymaps callback
    local function setup_keymaps(bufnr)
        ui_proposals.setup_buf_keymaps(bufnr, {
            review = function(buf)
                M.review_proposal_at_cursor(buf)
            end,
            accept = function(buf)
                M.accept_proposal_at_cursor(buf)
            end,
            reject = function(buf)
                M.reject_proposal_at_cursor(buf)
            end,
            inspect = function(buf)
                M.inspect_proposal_at_cursor(buf)
            end,
        })
    end

    -- Place signs and register deferred placement.
    -- Pass result.proposals directly (same refs stored in the data model via add()).
    -- proposals.all() returns deep copies which would break bufnr/extmark_id tracking.
    ui_proposals.place_all(result.proposals, setup_keymaps)

    -- Attach to loaded buffers for conflict detection
    for _, p in ipairs(result.proposals) do
        if p.bufnr and vim.api.nvim_buf_is_valid(p.bufnr) then
            proposals.attach_buffer(p.bufnr, on_expire)
        end
    end

    -- Notify user
    local file_set = {}
    for _, p in ipairs(result.proposals) do
        file_set[p.file] = true
    end
    local file_count = vim.tbl_count(file_set)
    local msg = string.format(
        "[ai-chat] %d proposal%s across %d file%s -- :copen or <leader>ar to review",
        #result.proposals,
        #result.proposals == 1 and "" or "s",
        file_count,
        file_count == 1 and "" or "s"
    )
    vim.notify(msg, vim.log.levels.INFO)

    -- Report parse warnings
    if #result.warnings > 0 then
        vim.notify(
            string.format(
                "[ai-chat] %d code block%s could not be parsed as proposals",
                #result.warnings,
                #result.warnings == 1 and "" or "s"
            ),
            vim.log.levels.WARN
        )
    end

    -- Emit user event
    local files = vim.tbl_keys(file_set)
    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AiChatProposalCreated",
        data = { count = #result.proposals, files = files },
    })
end

--- Review the proposal at the cursor position via diff split.
---@param bufnr? number Buffer to check (defaults to current buffer)
function M.review_proposal_at_cursor(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local proposals = require("ai-chat.proposals")
    local proposal = proposals.get_at_cursor(bufnr, line)

    if not proposal then
        vim.notify("[ai-chat] No proposal at cursor", vim.log.levels.INFO)
        return
    end

    if proposal.status == "expired" then
        vim.notify("[ai-chat] Proposal is outdated (target was edited)", vim.log.levels.WARN)
        return
    end

    -- Open diff split with the proposal content
    local block = {
        language = vim.bo[bufnr].filetype,
        content = table.concat(proposal.proposed_lines, "\n"),
        start_line = proposal.range.start,
        end_line = proposal.range.end_,
    }
    require("ai-chat.ui.diff").apply(block, bufnr)
end

--- Toggle inline preview for the proposal at the cursor position.
--- Shows/hides the full description and proposed code via virt_lines.
---@param bufnr? number Buffer to check (defaults to current buffer)
function M.inspect_proposal_at_cursor(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local proposals = require("ai-chat.proposals")
    local ui_proposals = require("ai-chat.ui.proposals")
    local proposal = proposals.get_at_cursor(bufnr, line)

    if not proposal then
        vim.notify("[ai-chat] No proposal at cursor", vim.log.levels.INFO)
        return
    end

    proposals.toggle_expanded(proposal.id)
    ui_proposals.toggle_preview(bufnr, proposal)
end

--- Reject/dismiss the proposal at the cursor position.
---@param bufnr? number Buffer to check (defaults to current buffer)
function M.reject_proposal_at_cursor(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local proposals = require("ai-chat.proposals")
    local ui_proposals = require("ai-chat.ui.proposals")
    local proposal = proposals.get_at_cursor(bufnr, line)

    if not proposal then
        vim.notify("[ai-chat] No proposal at cursor", vim.log.levels.INFO)
        return
    end

    proposals.reject(proposal.id)
    ui_proposals.remove(bufnr, proposal)
    ui_proposals.update_quickfix(proposals.all())

    local remaining = proposals.count_pending()
    if remaining == 0 then
        ui_proposals.clear_buf_keymaps(bufnr)
        vim.notify("[ai-chat] Proposal rejected -- all proposals resolved", vim.log.levels.INFO)
    else
        vim.notify(string.format("[ai-chat] Proposal rejected -- %d remaining", remaining), vim.log.levels.INFO)
    end

    -- Clean up keymaps if no more proposals on this buffer
    if not proposals.has_pending(bufnr) then
        ui_proposals.clear_buf_keymaps(bufnr)
    end

    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AiChatProposalRejected",
        data = { id = proposal.id, file = proposal.file },
    })
end

--- Accept the proposal at the cursor position (single undo entry).
---@param bufnr? number Buffer to check (defaults to current buffer)
function M.accept_proposal_at_cursor(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local proposals = require("ai-chat.proposals")
    local ui_proposals = require("ai-chat.ui.proposals")
    local proposal = proposals.get_at_cursor(bufnr, line)

    if not proposal then
        vim.notify("[ai-chat] No proposal at cursor", vim.log.levels.INFO)
        return
    end

    if proposal.status == "expired" then
        vim.notify("[ai-chat] Proposal is outdated (target was edited)", vim.log.levels.WARN)
        return
    end

    -- Apply as single undo entry
    proposals._accepting_id = proposal.id
    vim.api.nvim_buf_set_lines(bufnr, proposal.range.start - 1, proposal.range.end_, false, proposal.proposed_lines)
    proposals._accepting_id = nil

    proposals.accept(proposal.id)
    ui_proposals.remove(bufnr, proposal)
    ui_proposals.update_quickfix(proposals.all())

    local remaining = proposals.count_pending()
    if remaining == 0 then
        ui_proposals.clear_buf_keymaps(bufnr)
        vim.notify("[ai-chat] Proposal accepted -- all proposals resolved", vim.log.levels.INFO)
    else
        vim.notify(string.format("[ai-chat] Proposal accepted -- %d remaining", remaining), vim.log.levels.INFO)
    end

    if not proposals.has_pending(bufnr) then
        ui_proposals.clear_buf_keymaps(bufnr)
    end

    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "AiChatProposalAccepted",
        data = { id = proposal.id, file = proposal.file },
    })
end

--- Accept all pending proposals with confirmation.
function M.accept_all_proposals()
    M._ensure_init()
    local proposals = require("ai-chat.proposals")
    local ui_proposals = require("ai-chat.ui.proposals")
    local pending = proposals.get_pending()

    if #pending == 0 then
        vim.notify("[ai-chat] No pending proposals", vim.log.levels.INFO)
        return
    end

    local choice = vim.fn.confirm(
        string.format("Accept %d pending proposal%s?", #pending, #pending == 1 and "" or "s"),
        "&Yes\n&No",
        2
    )
    if choice ~= 1 then
        return
    end

    for _, p in ipairs(pending) do
        if p.bufnr and vim.api.nvim_buf_is_valid(p.bufnr) then
            -- Apply as single undo entry
            proposals._accepting_id = p.id
            vim.api.nvim_buf_set_lines(p.bufnr, p.range.start - 1, p.range.end_, false, p.proposed_lines)
            proposals._accepting_id = nil

            proposals.accept(p.id)
            ui_proposals.remove(p.bufnr, p)

            pcall(vim.api.nvim_exec_autocmds, "User", {
                pattern = "AiChatProposalAccepted",
                data = { id = p.id, file = p.file },
            })
        end
    end

    -- Clean up keymaps on all affected buffers
    local affected_buffers = {}
    for _, p in ipairs(pending) do
        if p.bufnr then
            affected_buffers[p.bufnr] = true
        end
    end
    for buf, _ in pairs(affected_buffers) do
        if not proposals.has_pending(buf) then
            ui_proposals.clear_buf_keymaps(buf)
        end
    end

    ui_proposals.update_quickfix(proposals.all())
    local file_count = vim.tbl_count(affected_buffers)
    vim.notify(
        string.format(
            "[ai-chat] %d proposal%s accepted across %d file%s",
            #pending,
            #pending == 1 and "" or "s",
            file_count,
            file_count == 1 and "" or "s"
        ),
        vim.log.levels.INFO
    )
end

--- Open the proposal quickfix list.
function M.open_proposal_quickfix()
    M._ensure_init()
    local proposals = require("ai-chat.proposals")
    local ui_proposals = require("ai-chat.ui.proposals")
    ui_proposals.update_quickfix(proposals.all())

    local pending = proposals.count_pending()
    if pending == 0 then
        vim.notify("[ai-chat] No pending proposals", vim.log.levels.INFO)
        return
    end

    vim.cmd("copen")
end

--- Jump to the next pending proposal across files.
function M.next_proposal()
    M._ensure_init()
    local proposals = require("ai-chat.proposals")
    local pending = proposals.get_pending()

    if #pending == 0 then
        vim.notify("[ai-chat] No pending proposals", vim.log.levels.INFO)
        return
    end

    -- Sort by file then line for predictable ordering
    table.sort(pending, function(a, b)
        if a.file == b.file then
            return a.range.start < b.range.start
        end
        return a.file < b.file
    end)

    -- Find the next proposal after the current cursor position
    local cur_buf = vim.api.nvim_get_current_buf()
    local cur_file = vim.api.nvim_buf_get_name(cur_buf)
    local cur_line = vim.api.nvim_win_get_cursor(0)[1]

    for _, p in ipairs(pending) do
        if p.file > cur_file or (p.file == cur_file and p.range.start > cur_line) then
            -- Jump to this proposal
            if p.file ~= cur_file then
                vim.cmd("edit " .. vim.fn.fnameescape(p.file))
            end
            vim.api.nvim_win_set_cursor(0, { p.range.start, 0 })
            return
        end
    end

    -- Wrap around to the first proposal
    local first = pending[1]
    if first.file ~= cur_file then
        vim.cmd("edit " .. vim.fn.fnameescape(first.file))
    end
    vim.api.nvim_win_set_cursor(0, { first.range.start, 0 })
end

-- ─── History ─────────────────────────────────────────────────────────

--- Save the current conversation.
---@param name? string  Optional name for the conversation.
function M.save(name)
    M._ensure_init()
    if require("ai-chat.config").get().history.enabled then
        require("ai-chat.history").save(get_conversation().get(), name)
        vim.notify("[ai-chat] Conversation saved", vim.log.levels.INFO)
    end
end

--- Load a conversation by ID.
---@param id? string  If nil, opens a history browser.
function M.load(id)
    M._ensure_init()
    if id then
        local conv = require("ai-chat.history").load(id)
        if conv then
            get_conversation().restore(conv)
            if state.ui.is_open then
                require("ai-chat.ui.render").render_conversation(state.ui.chat_bufnr, get_conversation().get())
                M._update_winbar()
            end
        end
    else
        M.history()
    end
end

--- Open the conversation history browser.
function M.history()
    M._ensure_init()
    require("ai-chat.history").browse(function(conv)
        if conv then
            M.load(conv.id)
        end
    end)
end

-- ─── Display ─────────────────────────────────────────────────────────

--- Show keybinding reference.
function M.show_keys()
    local keys = initialized and require("ai-chat.config").get().keys or require("ai-chat.config").defaults.keys
    local lines = { "ai-chat.nvim Keybindings", string.rep("-", 40) }
    local sections = {
        {
            "Global",
            {
                { "toggle", "Toggle chat panel" },
                { "send_selection", "Send selection to chat" },
                { "quick_explain", "Explain selection" },
                { "quick_fix", "Fix selection" },
                { "focus_input", "Focus chat input" },
                { "switch_model", "Switch model" },
                { "switch_provider", "Switch provider" },
                { "proposal_list", "Open proposal quickfix" },
                { "proposal_next", "Next pending proposal" },
                { "proposal_accept_all", "Accept all proposals" },
            },
        },
        {
            "Chat Buffer",
            {
                { "close", "Close panel" },
                { "cancel", "Cancel generation" },
                { "next_message", "Next message" },
                { "prev_message", "Previous message" },
                { "next_code_block", "Next code block" },
                { "prev_code_block", "Previous code block" },
                { "yank_code_block", "Yank code block" },
                { "apply_code_block", "Apply code block (diff)" },
                { "open_code_block", "Open code block in split" },
            },
        },
        {
            "Input",
            {
                { "submit_normal", "Send message (normal)" },
                { "submit_insert", "Send message (insert)" },
                { "recall_prev", "Previous in history" },
                { "recall_next", "Next in history" },
            },
        },
        {
            "Proposals (buffer-local, when pending)",
            {},
            -- Static keymaps (not config-driven, rendered with literal keys)
            static = {
                { "gi", "Inspect proposal (toggle preview)" },
                { "gp", "Review proposal at cursor (diff)" },
                { "ga", "Accept proposal at cursor" },
                { "gx", "Reject proposal at cursor" },
            },
        },
    }
    for _, section in ipairs(sections) do
        table.insert(lines, "")
        table.insert(lines, section[1] .. ":")
        for _, item in ipairs(section[2]) do
            local key = keys[item[1]]
            if key then
                table.insert(lines, string.format("  %-16s %s", key, item[2]))
            end
        end
        if section.static then
            for _, item in ipairs(section.static) do
                table.insert(lines, string.format("  %-16s %s", item[1], item[2]))
            end
        end
    end
    require("ai-chat.util.ui").show_in_split(lines)
end

--- Show resolved configuration.
function M.show_config()
    M._ensure_init()
    local display_config = vim.deepcopy(require("ai-chat.config").get())
    for _, pname in ipairs({ "anthropic", "openai_compat" }) do
        if display_config.providers[pname] and display_config.providers[pname].api_key then
            display_config.providers[pname].api_key = "***"
        end
    end
    local lines = vim.split(vim.inspect(display_config), "\n")
    table.insert(lines, 1, "ai-chat.nvim Resolved Configuration")
    table.insert(lines, 2, string.rep("-", 40))
    require("ai-chat.util.ui").show_in_split(lines)
end

-- ─── Internal ────────────────────────────────────────────────────────

function M._ensure_init()
    if not initialized then
        error("[ai-chat] Plugin not initialized. Call require('ai-chat').setup() first.")
    end
end

--- Track the last code buffer the user was editing.
function M._setup_code_buffer_tracking()
    vim.api.nvim_create_autocmd("BufEnter", {
        group = vim.api.nvim_create_augroup("ai-chat-code-buffer", { clear = true }),
        callback = function(args)
            local bufnr = args.buf
            if vim.bo[bufnr].buftype ~= "" then
                return
            end
            if vim.api.nvim_buf_get_name(bufnr) == "" then
                return
            end
            state.last_code_bufnr = bufnr
        end,
    })
end

function M._update_winbar()
    if state.ui.is_open and state.ui.chat_winid and vim.api.nvim_win_is_valid(state.ui.chat_winid) then
        require("ai-chat.ui.chat").update_winbar(state.ui.chat_winid, get_conversation().get())
    end
end

return M
