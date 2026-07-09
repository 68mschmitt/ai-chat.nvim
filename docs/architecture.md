# Architecture

**Thesis:** Every module in this plugin exists at one of three rates of change — UI, business logic, or provider integration — and a faster-changing layer must never dictate the structure of a slower one.

*Perspectives: Rich Hickey (simplicity, data, state management) and Edsger Dijkstra (correctness, separation of concerns). Where they disagree — Hickey favors dynamic data flow, Dijkstra favors static proofs — we side with Hickey for a 4,000-line Lua plugin where formal verification is impractical, but adopt Dijkstra's insistence on verified invariants at module boundaries.*

---

## Principles

### 1. Separate by rate of change, not by type

Organize modules by how often they change, not by what kind of thing they are. The three layers are:

| Layer | Changes when… | Examples |
|---|---|---|
| UI / Buffer management | Neovim API changes | `ui/`, `highlights.lua` |
| Conversation / business logic | We add features | `conversation.lua`, `pipeline.lua`, `stream.lua` |
| Provider integration | Someone else changes their API | `providers/*.lua` |

**Rationale:** A provider API change should require editing exactly one file. If it forces changes in conversation logic or UI rendering, the boundary has leaked.

**Violation:** A render function that checks `if provider == "anthropic"` to decide how to display thinking blocks. The provider adapter should normalize thinking content before it crosses the boundary.

### 2. Data over objects, always

Messages, conversations, configs, and errors are plain Lua tables. No metatables for domain data. No methods attached to data structures. Functions operate on data; data does not operate on itself.

**Rationale:** Plain data is inspectable, serializable, copyable, and debuggable. Metatables hide behavior and create coupling between data and the code that processes it.

**Violation:** Adding a `:send()` method to a conversation table. Conversations are data. `pipeline.send()` is a function that operates on conversation data. These are separate concerns.

### 3. Immutability is the default

Config is frozen after `resolve()`. Conversation state is accessed through `get()` which returns a deep copy. The stream state machine transitions are validated at load time and never modified at runtime.

**Rationale:** Every mutable reference is a synchronization bug waiting to happen. In an async plugin where `vim.schedule` callbacks interleave with user actions, shared mutable state is the primary source of corruption.

**Violation:** Returning `state.messages` directly from `conversation.get()` instead of `vim.deepcopy(state)`. A caller mutates the returned table, corrupting the conversation for the next render.

### 4. State is a liability — hold the minimum

In-memory state should be the minimum necessary for the current operation. Persistent data belongs on the filesystem (JSON files via `history/store.lua`, `state.lua`). No in-memory caches that duplicate what's on disk unless there's a measured performance reason.

**Rationale:** Every piece of held state must be synchronized, persisted, and debugged. The plugin runs inside Neovim where the process can die at any moment. Filesystem state survives; in-memory state does not.

**Violation:** Caching the full conversation history index in memory and trying to keep it in sync with disk. The store reads the index from disk on each `list()` call — simple, correct, no sync bugs.

### 5. Make state transitions explicit

Use state machines with named phases and validated transitions, not boolean flags. The stream lifecycle (`idle → streaming → retrying → idle`) is the canonical example: every legal transition is declared in a table, every illegal transition raises an error, and the transition table is verified at load time.

**Rationale:** A boolean `is_streaming` flag cannot express "streaming but about to retry." Named phases can. Declared transitions make illegal states unrepresentable in code.

**Violation:** Adding `is_retrying = true` alongside `is_streaming = true` instead of a single `phase = "retrying"`. Two booleans create four states; only three are legal. The fourth is a bug.

### 6. Dependencies flow in one direction

`init.lua` coordinates all modules. Modules at the same layer may not require each other. Lower layers never require upper layers. Provider adapters never require UI modules. Conversation logic never requires provider modules directly.

```
init.lua (coordinator)
  ├── pipeline.lua (orchestration)
  │     ├── conversation.lua (pure data)
  │     ├── stream.lua (lifecycle state machine)
  │     └── providers/ (adapters)
  ├── ui/ (buffer management)
  └── config.lua (resolved state)
```

**Rationale:** Circular dependencies make modules untestable in isolation and create initialization order bugs. One-directional flow means you can understand any module by reading only the modules it imports.

**Violation:** `conversation.lua` importing `providers/anthropic.lua` to check if thinking mode is supported. That knowledge belongs in the provider adapter. Conversation logic operates on normalized data.

### 7. The provider adapter absorbs all instability

Every provider-specific concern — authentication, request format, response parsing, error code mapping, streaming protocol (SSE vs NDJSON vs event frames) — lives inside the adapter. Above the adapter boundary, the plugin sees only: messages in, chunks out, canonical error codes, and usage stats.

**Rationale:** Models die. APIs mutate. Companies pivot. The adapter is the sacrificial layer that absorbs all of this. When Anthropic changes their API version header, exactly one file changes.

**Violation:** `pipeline.lua` building Anthropic-specific request headers. The pipeline sends a normalized request; the adapter translates it into the provider's wire format.

---

## Violations

### V1: Provider logic leaking upward

Any `if provider == "X"` check outside `providers/` is a boundary violation. Provider-specific behavior must be handled by the adapter and normalized before it crosses the boundary. The thinking block format (Anthropic-specific) is converted to `<thinking>` tags inside the Anthropic adapter; the UI module processes generic tags without knowing which provider generated them.

### V2: Shared mutable references

Returning a direct reference to internal state instead of a copy. This creates invisible coupling where one module's mutation affects another module's behavior. Every `.get()` function in this codebase returns `vim.deepcopy()` — this is non-negotiable.

### V3: Implicit state transitions

Using boolean flags (`is_streaming`, `is_retrying`, `has_error`) instead of a state machine. Boolean combinations create exponential state spaces where most combinations are illegal. The stream module's explicit `TRANSITIONS` table is the pattern to follow.

### V4: Configuration mutated without ceremony

Bypassing `config.set()` to directly modify the resolved config table. The freeze/unfreeze mechanism exists to make accidental mutation impossible and intentional mutation auditable. Any module that needs to change config at runtime goes through the controlled `set()` path with lifecycle awareness.
