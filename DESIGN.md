# ai-chat.nvim — Design Document

> A transparent, native-feeling AI chat interface for neovim that treats the
> AI as a knowledgeable colleague — not a magic autocomplete that does your
> thinking for you.

## Design Philosophy

1. **Transparency over magic.** The user always knows what context the AI sees,
   what it costs, and how to override any suggestion.
2. **Native over ported.** Every interaction should feel like neovim, not a
   browser pretending to be a terminal. Buffers, splits, motions, operators.
3. **Minimal over maximal.** Ship the smallest useful thing first. Every feature
   must justify its complexity budget.
4. **Local-first.** Default to Ollama (local, free, private). Cloud providers
   are opt-in, never assumed.
5. **Composable over monolithic.** Integrate with the neovim ecosystem
   (treesitter, LSP) but never depend on it. Degrade gracefully.

## Core Decisions

### Pure Lua — No External Binary

The plugin is written entirely in Lua. No Rust sidecars, no Go binaries, no
build steps.

**Rationale:**
- `vim.system()` provides async process spawning with streaming via callbacks
- `vim.loop` (libuv) gives async I/O, timers, and process management
- Token counting can be approximated in Lua (word count × 0.75)
- The plugin installs with a single line in lazy.nvim and works immediately
- No platform-specific binaries, no `:AiChatBuild` step

**Zero dependencies.** HTTP is handled by `vim.system()` calling `curl` directly
with streaming stdout callbacks. No external Lua libraries. Even the test
harness is a self-contained ~80-line Lua file with no third-party dependencies.

### Vertical Split — Not Floating Windows

The primary UI is a vertical split on the right side of the editor. Not a
floating window, not a tab.

**Rationale:**
- Persistent: visible alongside code, doesn't block the editor
- Navigable: standard window commands (`<C-w>h`, `<C-w>l`) work naturally
- Resizable: `<C-w><` and `<C-w>>` adjust width
- Familiar: same paradigm as file explorers, terminals, help windows
- A floating window steals focus and can't be used alongside code

The split width defaults to 25% of the editor width (minimum 60 columns).

### Provider Priority

Supported providers, in order of priority:

| Priority | Provider | Rationale |
|----------|----------|-----------|
| 1 | Ollama | Local, free, private, zero-config |
| 2 | Anthropic | Direct Claude access |
| 3 | Amazon Bedrock | Enterprise Claude deployments |
| 4 | OpenAI-compatible | Covers OpenAI, Azure, Groq, Together, LM Studio |

Default provider is **Ollama** — the only provider that requires zero
configuration, costs nothing, and sends no data anywhere.

### Conversation Model

- **Multi-turn by default.** Messages accumulate in a conversation.
- **Persistent across restarts.** Conversations are saved to
  `vim.fn.stdpath("data") .. "/ai-chat/history/"` as JSON.
- **One active conversation per neovim instance.** No tabs, no multiplexing.
  Use `/clear` or `/save` to manage conversations.
- **Context is explicit.** Every message shows what context was attached.
  No hidden system prompts beyond a minimal instruction prefix.

### Context Window Management

Long conversations will exceed the model's context window. The plugin handles
this transparently:

**Truncation strategy: oldest messages first, system prompt always preserved.**
No summarization — that requires an extra API call, adds latency, costs money,
and introduces a black-box transformation of the user's conversation. The user
should know exactly what the AI sees. Summarization violates the transparency
principle.

The winbar shows when truncation is active: `msgs: 24 (ctx: 12)`. A one-time
`vim.notify` fires when truncation first kicks in for a conversation. The user
is never surprised about what the AI does or doesn't remember.

### Context Collection Feedback

When context references (`@buffer`, `@selection`, `@diagnostics`, `@diff`,
`@file`) are resolved, the plugin confirms what was collected via a brief
`vim.notify`:

```
@buffer: main.lua (142 lines, ~2,847 tokens)
@selection: main.lua:42-45 (4 lines, ~12 tokens)
@diagnostics: main.lua (3 errors, 2 warnings)
```

This closes the transparency gap between typing the tag and seeing the result.
Without feedback, the user doesn't know whether `@buffer` targeted the right
file, whether the selection was empty, or how much of their context budget was
consumed — until the AI responds. Context collection feedback makes the
invisible visible, consistent with the transparency principle.

### Configuration Ownership

`config.lua` owns the resolved configuration state. `init.lua` calls
`config.resolve(user_opts)` during `setup()`, and `config.lua` stores the
result internally. Other modules call `config.get()` to access the resolved
config. This avoids the anti-pattern of `config.lua` reaching back into
`init.lua` via `pcall(require, "ai-chat")` — a circular dependency that
creates fragility during testing and module load order changes.

### Code Application Model

When the AI suggests code, the user can apply it via a diff-based workflow:

1. Cursor on a code block in the chat → press `ga` ("go apply")
2. A vertical diff split opens: left = original file, right = suggested change
3. User reviews with standard diff navigation (`]c`, `[c`, `do`, `dp`)
4. Accept with `:diffoff | only` or reject by closing the diff buffer

Note: Code block navigation in the chat buffer uses `]b`/`[b` (for "block")
to avoid collision with neovim's built-in `]c`/`[c` diff hunk navigation.
When in diff mode, `]c`/`[c` work as expected for hunk navigation.

This reuses neovim's built-in diff mode. No custom diff rendering, no
reinventing the wheel.

### Agent-Initiated Changes: The Proposal Queue

The chat-then-apply model above is *reactive* — the user asks, the AI answers,
the user decides what to apply. The proposal queue extends this to support
*proactive* changes — where the AI suggests edits to specific files as part of
completing a task.

**Core constraint: nothing changes until the user says so.** The AI can propose
changes, but the buffer is never modified without explicit user consent. This
preserves the trust model: the default is "nothing happens unless you act,"
not "everything happens unless you object."

The design uses a three-layer system that maps entirely to native neovim
paradigms:

**Layer 1 — Signs + Virtual Text (passive notification).**
When the AI proposes a change, a sign appears in the gutter and right-aligned
virtual text shows a summary. The buffer is untouched. The user's undo tree is
unaffected. This is the same pattern as LSP diagnostics — visible, familiar,
non-intrusive.

**Layer 2 — Quickfix List (multi-file awareness).**
Pending proposals across files populate a standard quickfix list. Users navigate
with `:cnext`/`:cprev` or `]q`/`[q`. Each entry shows the AI's one-line intent
so the user sees *why* before *what*. No custom panels — quickfix is native.
Files not yet open are still listed; an autocommand defers sign placement until
the buffer is loaded.

**Layer 3 — Diff Review (reuse existing `ui/diff.lua`).**
When the user is ready to review, they get the same diff split used for
chat-based code application. Left = original, right = proposed. Same keymaps,
same workflow. The only difference is the source of the code block — from the
proposal queue instead of the chat buffer.

**Notification:** When proposals arrive, a single `vim.notify` informs the user.
No modal dialogs, no floating windows, no focus stealing. The user finishes
their thought and reviews when ready.

**Undo integration:** Each accepted proposal is a single atomic undo entry
(one `nvim_buf_set_lines` call). `u` reverts the entire AI change as one
operation. No fragmented undo trees.

**Conflict handling:** Proposals track a target line range. If the user edits
within that range, the proposal is marked expired. No merge algorithms, no
three-way diffs. Simple invalidation via `nvim_buf_attach`.

See `UX.md` for proposal keybindings and `ARCHITECTURE.md` for the data model
and module structure.

### Inline Annotations: AI-Guided Code Comprehension

Proposals place actionable changes in the buffer. Annotations extend the same
overlay infrastructure for a different purpose: placing **non-actionable
information** inline with the user's code to accelerate learning and
comprehension.

The user asks the AI to explain a file or selection. Instead of a wall of text
in the chat buffer that the user must mentally cross-reference with their code,
the AI's explanations appear as inline annotations — pinned to the specific
lines they describe. The explanation is *at* the code, not *about* the code
from a distance.

**Why this fits the plugin's philosophy:**
- Annotations don't modify the buffer. They're pure information overlay. The
  trust model is trivially satisfied — there's nothing to consent to.
- They use extmarks in a dedicated namespace, not `vim.diagnostic`. This avoids
  polluting the diagnostic ecosystem with non-diagnostic data and prevents
  confusion with real LSP errors and warnings.
- The user invokes annotations explicitly via `/annotate`. The AI never
  annotates without being asked.

**Implementation primitive: `nvim_buf_set_extmark` with `virt_lines`.**
Annotations are collapsed by default (sign + short `virt_text` summary) and
expand on demand (`virt_lines` below the annotated line for the full
explanation). This avoids visual clutter while keeping information one keypress
away. Extmarks track line movement automatically — if the user inserts lines
above an annotation, the annotation moves with its target.

**Response parsing:** Annotations require the AI to return structured output
with line references (e.g., `[annotation: line 34] explanation text`). This is
a design choice — the system prompt for `/annotate` instructs the AI to
reference specific line numbers and produce concise, targeted explanations. The
parser uses a multi-strategy fallback chain (exact format → relaxed brackets →
markdown headers) to tolerate LLM formatting inconsistency. The full AI
response is always shown in the chat buffer (transparency); the plugin parses
it to place the inline extmarks. Parsing failures degrade gracefully — the
chat response is still readable, the annotations just don't appear inline.

**Ephemerality:** Annotations are ephemeral — they live for the session and are
not persisted to disk. Closing and reopening a file clears them. The
conversation history preserves the AI's response; annotations are a display
convenience, not a data layer.

**Relationship to proposals:** Annotations share the overlay infrastructure
built for v0.4 (sign placement, virtual text, buffer-local keymaps, namespace
cleanup, `BufRead` deferral). The genuinely new pieces are `virt_lines`
rendering and the expand/collapse toggle. Shared plumbing is extracted into
`ui/overlays.lua`.

See `UX.md` for annotation interaction details and `ARCHITECTURE.md` for the
annotation data model.

## What This Plugin Is Not

- **Not an inline completion engine.** Use copilot.lua or cmp-ai for that.
  This plugin is a chat interface. The two can coexist.
- **Not a VS Code extension.** No webviews, no custom renderers, no
  electron-style panels.
- **Not a RAG engine.** No local embedding, no vector databases. If you need
  project-wide context, you send files explicitly.
- **Not an autonomous agent.** The AI can *propose* changes, but it never
  modifies buffers, runs shell commands, or acts without explicit user approval.
  Proposals are visible, reviewable, and dismissible. The user always holds
  the final decision.

## Contribution Principles

These principles govern all development and contribution decisions:

1. **No feature without a removal plan.** Every feature must be possible to
   disable or remove without breaking the plugin. If a feature can't be cleanly
   excised, it's too tightly coupled.
2. **Each version must be usable on its own.** No "foundation" releases that
   deliver zero user value.
3. **Cut scope, not quality.** If a version is running late, remove features.
   Don't ship broken ones.
4. **User feedback drives priority.** After v0.1, the roadmap should be
   influenced by what people actually use and request.
5. **Transparency is non-negotiable.** Any change that hides information from
   the user, auto-applies without consent, or introduces invisible behavior
   violates the core design philosophy and will be rejected.

These principles should be documented in `CONTRIBUTING.md` when the project
accepts external contributions (targeted for v1.0).

## Key References

- See `ARCHITECTURE.md` for module structure and data flow
- See `UX.md` for UI layout, keybindings, and display format
- See `API.md` for provider interfaces and plugin API
- See `ROADMAP.md` for MVP definition and version plan
