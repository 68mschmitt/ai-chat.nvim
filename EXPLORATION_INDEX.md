# ai-chat.nvim Codebase Exploration — Documentation Index

This directory contains comprehensive documentation of the ai-chat.nvim codebase structure, architecture, and patterns. These documents are designed to support development of the proposal review feature.

## 📄 Documentation Files

### 1. **CODEBASE_EXPLORATION.md** (25 KB)
**Comprehensive reference covering the entire codebase structure.**

Contains:
- **§1** Directory tree with line counts for all 43 Lua files
- **§2** Module dependency graph showing coordinator vs. boundary modules
- **§3** Complete `ga` (apply code) workflow end-to-end with flow diagrams
- **§4** Sign, extmark, and virtual text usage patterns (8 locations documented)
- **§5** User event patterns (7 events with code locations)
- **§6** Test infrastructure (framework, organization, patterns)
- **§7** Existing proposal-related code (none found — greenfield)
- **§8** Key architectural patterns (coordinator, boundary rule, state ownership, etc.)
- **§9** Send pipeline flow (detailed orchestration)
- **§10** Configuration structure (defaults, per-project overrides)
- **§11** Highlight groups (11 groups defined)
- **§12** Lifecycle autocommands (3 guards documented)
- **§13** Context collection (5 collector types)
- **§14** Conversation state management
- **§15** Streaming architecture with retry policy
- **§16** send() function public API
- **§17** Summary for proposal feature (what exists, what's missing, recommended architecture)

**Best for:** Understanding the full system, tracing workflows, learning architectural patterns.

---

### 2. **QUICK_REFERENCE.md** (9.3 KB)
**Quick lookup guide for common tasks and integration points.**

Contains:
- **File Locations Quick Map** — Table of features and their primary files
- **Key Functions** — Code block detection, diff application, user events, extmarks, slash commands
- **Extmark Namespace** — Single namespace used throughout
- **Highlight Groups** — 11 available groups for styling
- **Autocommand Groups** — Lifecycle and code buffer tracking
- **Configuration Access Pattern** — How to access config in different module types
- **Message Structure** — Complete message object schema
- **State Ownership** — Table of what each module owns
- **Boundary Rule Violations** — Examples of what NOT to do
- **Testing Patterns** — How to write tests
- **Diff Mode Cleanup Pattern** — Reusable pattern for diff split cleanup
- **Event Dispatch Pattern** — How to dispatch user events
- **Code Block Fence Detection** — Regex patterns for fence detection
- **Proposal Feature Integration Points** — 4 specific integration areas
- **File Modification Checklist** — 8 files to modify for proposal feature
- **Common Patterns to Reuse** — 4 patterns with code examples
- **Dependency Injection Pattern** — How to pass dependencies
- **Error Handling Pattern** — How to handle errors safely

**Best for:** Quick lookups, copy-paste patterns, integration points, checklists.

---

## 🎯 How to Use These Documents

### For Understanding the Codebase
1. Start with **QUICK_REFERENCE.md** § "File Locations Quick Map" to get oriented
2. Read **CODEBASE_EXPLORATION.md** § "Architecture Highlights" for design principles
3. Dive into specific sections as needed (e.g., § "The `ga` Workflow" for code application)

### For Implementing the Proposal Feature
1. Review **CODEBASE_EXPLORATION.md** § "Summary for Proposal Feature"
2. Check **QUICK_REFERENCE.md** § "Proposal Feature Integration Points"
3. Use **QUICK_REFERENCE.md** § "File Modification Checklist" as your task list
4. Reference **QUICK_REFERENCE.md** § "Common Patterns to Reuse" while coding

### For Specific Tasks
- **Understanding how code blocks are detected:** CODEBASE_EXPLORATION.md § "The `ga` Workflow" → "Code Block Detection Algorithm"
- **Adding a new slash command:** QUICK_REFERENCE.md § "Slash Commands" + CODEBASE_EXPLORATION.md § "Send Pipeline Flow"
- **Dispatching a user event:** QUICK_REFERENCE.md § "Event Dispatch Pattern" + CODEBASE_EXPLORATION.md § "User Event Patterns"
- **Adding UI annotations:** QUICK_REFERENCE.md § "Extmark Namespace" + CODEBASE_EXPLORATION.md § "Sign, Extmark, and Virtual Text Usage"
- **Writing tests:** QUICK_REFERENCE.md § "Testing Patterns" + CODEBASE_EXPLORATION.md § "Test Infrastructure"

---

## 📊 Codebase Statistics

| Metric | Value |
|--------|-------|
| Core Lua files | 43 files, 5,963 lines |
| Test files | 13 files, 2,367 lines |
| Total | 56 files, 8,330 lines |
| Largest module | providers/bedrock.lua (439 lines) |
| Largest test file | pipeline_spec.lua (392 lines) |

---

## 🏗️ Architecture at a Glance

```
init.lua (Coordinator)
  ├─ Owns: UI state (bufnr, winid)
  ├─ Lazy-loads: conversation, stream, pipeline
  └─ Exports: Public API (setup, open, close, send, etc.)

config.lua (Configuration Owner)
  ├─ Owns: Resolved configuration
  └─ Exports: get(), set(), resolve(), validate()

conversation.lua (Conversation State)
  ├─ Owns: Messages, provider, model
  └─ Exports: append(), build_provider_messages(), etc.

stream.lua (Streaming Orchestration)
  ├─ Owns: Streaming state, retry count
  └─ Exports: send(), cancel(), is_active()

pipeline.lua (Send Pipeline)
  ├─ Orchestrates: Context collection, message building, provider call
  └─ Exports: send(), reset(), get_last_request()

ui/* (UI Modules)
  ├─ chat.lua: Chat split window management
  ├─ input.lua: Input area management
  ├─ render.lua: Message rendering, code blocks
  ├─ diff.lua: Diff-based code application
  └─ thinking.lua: Thinking block rendering

commands/* (Command System)
  ├─ init.lua: Command router
  └─ slash.lua: Slash command definitions

context/* (Context Collection)
  ├─ init.lua: Context coordinator
  ├─ buffer.lua: @buffer collector
  ├─ selection.lua: @selection collector
  ├─ diagnostics.lua: @diagnostics collector
  ├─ diff.lua: @diff collector
  └─ file.lua: @file:path collector

providers/* (Provider Implementations)
  ├─ anthropic.lua: Anthropic provider
  ├─ bedrock.lua: AWS Bedrock provider
  ├─ openai_compat.lua: OpenAI-compatible provider
  └─ ollama.lua: Ollama provider
```

---

## 🎯 Key Design Principles

1. **Coordinator Pattern** — Single coordinator (init.lua) owns UI state and module wiring
2. **Boundary Rule** — Coordinator modules can require anything; boundary modules receive dependencies as arguments
3. **State Ownership** — Each module owns specific state (config, conversation, streaming, UI)
4. **Namespace Isolation** — Extmarks, autocommands, and highlights use isolated namespaces
5. **Error Handling** — All external calls wrapped in pcall(); errors classified and auto-retried
6. **User Events** — Extensible event system for integrations (AiChatPanelOpened, AiChatResponseDone, etc.)
7. **Configuration** — Deep merge with defaults; per-project overrides; runtime updates

---

## 📋 Proposal Feature Readiness

### What Exists (Ready to Reuse)
- ✅ Diff split infrastructure (ui/diff.lua)
- ✅ Code block detection (ui/render.lua:get_code_block_at_cursor)
- ✅ User event system (vim.api.nvim_exec_autocmds)
- ✅ Extmark system for UI annotations
- ✅ Slash command framework (commands/slash.lua)
- ✅ Configuration system with per-project overrides

### What's Missing (Greenfield)
- ❌ Proposal state management (new module)
- ❌ Proposal diff split variant (extend ui/diff.lua)
- ❌ Proposal approval/rejection commands (extend commands/slash.lua)
- ❌ Proposal event dispatches (AiChatProposalCreated, etc.)
- ❌ Proposal UI indicators (extmarks for approval status)
- ❌ Proposal history/persistence (extend history/store.lua)

### Recommended Architecture
1. **New module:** `lua/ai-chat/proposals.lua` (proposal state management)
2. **Extend:** `lua/ai-chat/ui/diff.lua` (add proposal mode)
3. **Extend:** `lua/ai-chat/commands/slash.lua` (add /approve, /reject)
4. **Extend:** `lua/ai-chat/init.lua` (add public API)
5. **Extend:** `lua/ai-chat/lifecycle.lua` (guard proposal state)
6. **Extend:** `lua/ai-chat/highlights.lua` (add AiChatProposal* groups)
7. **Extend:** `lua/ai-chat/history/store.lua` (persist proposals)

---

## 🔗 Cross-References

### Understanding the `ga` (Apply Code) Workflow
- **CODEBASE_EXPLORATION.md** § "The `ga` (Apply Code) Workflow — End-to-End"
- **QUICK_REFERENCE.md** § "Code Block Fence Detection"
- **QUICK_REFERENCE.md** § "Diff Mode Cleanup Pattern"

### Understanding User Events
- **CODEBASE_EXPLORATION.md** § "User Event Patterns"
- **QUICK_REFERENCE.md** § "Event Dispatch Pattern"

### Understanding Extmarks and UI
- **CODEBASE_EXPLORATION.md** § "Sign, Extmark, and Virtual Text Usage"
- **QUICK_REFERENCE.md** § "Extmark Namespace"
- **QUICK_REFERENCE.md** § "Highlight Groups Available"

### Understanding Configuration
- **CODEBASE_EXPLORATION.md** § "Configuration Structure"
- **QUICK_REFERENCE.md** § "Configuration Access Pattern"

### Understanding Testing
- **CODEBASE_EXPLORATION.md** § "Test Infrastructure"
- **QUICK_REFERENCE.md** § "Testing Patterns"

### Understanding Patterns to Reuse
- **QUICK_REFERENCE.md** § "Common Patterns to Reuse"
- **QUICK_REFERENCE.md** § "Dependency Injection Pattern"
- **QUICK_REFERENCE.md** § "Error Handling Pattern"

---

## 📚 Additional Resources

- **AGENTS.md** — Instructions for AI coding agents (design decisions, dependency boundary rule)
- **DESIGN.md** — Design principles and contribution guidelines
- **ARCHITECTURE.md** — High-level architecture overview
- **API.md** — Public API documentation
- **UX.md** — User experience guidelines

---

## ✨ Quick Start for Proposal Feature Development

1. **Read:** CODEBASE_EXPLORATION.md § "Summary for Proposal Feature"
2. **Review:** QUICK_REFERENCE.md § "Proposal Feature Integration Points"
3. **Check:** QUICK_REFERENCE.md § "File Modification Checklist"
4. **Reference:** QUICK_REFERENCE.md § "Common Patterns to Reuse" while coding
5. **Test:** QUICK_REFERENCE.md § "Testing Patterns"

---

## 📝 Notes

- All documentation is read-only and reflects the codebase as of March 26, 2026
- Line numbers and file paths are accurate as of the exploration date
- The codebase follows strict architectural patterns (coordinator, boundary rule, state ownership)
- All external calls are wrapped in pcall() for safety
- The test framework has zero external dependencies

---

**Generated:** March 26, 2026  
**Codebase Version:** Current (as of exploration date)  
**Documentation Format:** Markdown  
**Total Documentation:** 34.3 KB across 2 files
