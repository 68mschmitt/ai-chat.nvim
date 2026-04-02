# Architecture

**Thesis:** Keep things separate that are separate — data from context, rendering from modeling, protocol from implementation — so that each module can be understood, tested, and changed without holding the entire system in your head.

---

## Principles

### 1. Pure data modules must have no outward dependencies and no knowledge of their consumers

**Rule:** A module designated as "pure data" receives everything it needs through function arguments and returns plain Lua tables. It never calls `require` on UI, provider, or editor modules. Information flows *in* through arguments and *out* through return values.

**Rationale:** A pure module is trivially testable, trivially relocatable, and locally reasoned about. The moment it reaches out to learn about its context, you have complected *what the data is* with *where the data lives*.

**Violation:** `conversation.lua` adds a `require("ai-chat.providers").get_model_info()` call inside `_get_context_window` to auto-detect context sizes. Now conversation depends on the provider registry, which depends on config, which depends on resolution state. You can no longer test conversation without standing up the entire provider stack.

---

### 2. Dependencies flow inward: edge → orchestration → data — never the reverse

**Rule:** Edge modules (providers, UI/render) depend on nothing internal. Orchestration modules (pipeline, stream, init) coordinate between edges. Data modules (conversation, errors, config) are leaves — used by everything, using nothing. A module may depend on things at its own layer or deeper. Never shallower.

**Rationale:** Unidirectional dependency flow means changes propagate in one direction. If `render.lua` never requires `pipeline.lua`, you can restructure orchestration without touching the UI. If `conversation.lua` never requires `stream.lua`, you can swap the streaming model without touching the data layer.

**Violation:** `render.lua` requires `stream.lua` to check `stream.is_active()` for a "streaming..." indicator. Now render depends on stream, and stream already calls render through callbacks. You have a cycle. The correct path: stream passes a status flag *down* to render through the callback arguments.

---

### 3. State has exactly one owner — everyone else gets snapshots or callbacks

**Rule:** Every piece of mutable state has exactly one module that owns it, mutates it, and is responsible for its consistency. Other modules receive deep copies (snapshots) or are notified of changes via callbacks. Never hand out mutable references to owned state.

**Rationale:** The state ownership map is: conversation state → `conversation.lua`, streaming state → `stream.lua`, UI refs → `init.lua`, config → `config.lua`, pipeline state → `pipeline.lua`. This only works if you never create a second path to mutate the same data.

**Violation:** A module holds a reference from `config.get()` and does `ref.chat.thinking = true`, silently mutating global config without going through `config.set()`. The owner's validation and notification logic is bypassed. Every subsequent reader sees the mutation with no audit trail.

---

### 4. The provider boundary is a protocol — nothing provider-specific leaks above the adapter

**Rule:** Every provider implements the same four functions. The orchestration layer sees one uniform shape. Nothing above `providers/` may know about URL schemes, auth mechanisms, SSE formats, or error taxonomies. The adapter absorbs all of that.

**Rationale:** The word "adapter" means: translate between two worlds. The Anthropic system-prompt-as-top-level-field quirk, the Bedrock base64 envelope, the Ollama NDJSON format — all of it stays inside the adapter. If you find yourself writing `if provider_name ==` anywhere outside the providers directory, you are leaking the abstraction.

**Violation:** `pipeline.lua` adds a special case: `if provider_name == "anthropic" and opts.thinking then opts.temperature = nil end`. This Anthropic-specific constraint belongs inside `providers/anthropic.lua`, where it already lives. Push it down.

---

### 5. Orchestration is wiring, not logic — if it makes decisions about data, it is in the wrong place

**Rule:** `pipeline.lua` and `stream.lua` exist to connect modules — to call them in the right order, pass the right arguments, and route callbacks. They contain sequencing, error routing, and lifecycle management. They do not contain business logic about message formatting, truncation strategy, or cost calculation.

**Rationale:** When logic lives in the orchestrator, you get a God module that knows everything about everything. When it stays thin, each piece of logic lives next to the data it operates on, and the orchestrator is a wiring diagram you can read top-to-bottom.

**Violation:** Someone adds "if the user's message contains a code block, automatically prepend a code review system instruction" to `pipeline.send()`. That is data transformation logic. It belongs in `conversation.lua` as a message-building concern, not in the pipeline.

---

### 6. The editor is a side effect — quarantine it behind vim.schedule and never let it infect the data model

**Rule:** Every interaction with Neovim's buffer/window API must happen inside `vim.schedule()` and must live exclusively in the `ui/` directory. No module outside `ui/` touches a buffer or window directly. The data model must be testable without a running Neovim instance.

**Rationale:** The editor is an I/O device. It is where you *render* data, not where data *lives*. The moment the data model depends on buffer state, you cannot test it, serialize it, or reason about it without simulating an editor.

**Violation:** Someone adds a `BufDelete` autocmd in `conversation.lua` to auto-save when the chat buffer closes. Now the pure data module depends on Neovim's autocmd system. Instead: the autocmd belongs in `ui/chat.lua`, which calls up to `init.lua`, which calls `history.save()` with the conversation snapshot.

---

### 7. Streaming is a state machine — represent it as one, with explicit states and legal transitions

**Rule:** The streaming lifecycle defines its states explicitly — idle, streaming, retrying, cancelling — and every function begins by asserting that the current state is among its legal preconditions. Encode the state as a single named value, not as predicates over scattered booleans.

**Rationale:** A collection of flags (`active`, `cancel_fn`, `retry_count`, `retry_timer`) whose combinations implicitly define states is boolean blindness. With four independent flags you have sixteen possible combinations, of which perhaps five are meaningful. The remaining eleven are bugs waiting for a sequence of callbacks to arrive in an unexpected order.

**Violation:** User cancels during a retry backoff. `cancel()` calls `cancel_fn` (there is no process — we are between retries), sets `active = false`. The retry timer fires, checks `active`, sees false, stops. But what if the timer already fired and `_do_send()` is in progress? Each question has an answer in the code, but the answers are implicit in flag combinations rather than explicit in a state name.

---

### 8. Grow by accretion, not by mutation — new capabilities are new modules or new functions, never changes to existing signatures

**Rule:** When adding a new provider, UI feature, or data capability, add a new file or function. Do not change the signature of existing public functions. If you must extend a contract, make new fields optional with well-defined defaults so every existing caller continues to work unchanged.

**Rationale:** A system that grows by accretion is one where new things are added and old things continue to work. When adding a fifth provider, you create one new file in `providers/` and register it. You touch zero other files. If adding a provider requires changes to `pipeline.lua`, `stream.lua`, or `conversation.lua`, the abstraction has failed.

**Violation:** A "vision" provider requires modifying `conversation.append()` to accept attachments, `build_provider_messages()` to include base64 data, `pipeline.send()` for file reading, and `render.lua` for image display. Every layer is touched. The accretive approach: `conversation.append()` already accepts a table — if it has an `attachments` field, it stores it. Each layer handles its own concern.

---

## Anti-Patterns

### The Complected Data Module
A module labeled "pure data" that calls `require` on other modules, contains hardcoded metadata that belongs in a registry, or touches the editor API. The label becomes a lie that actively misleads the next contributor into thinking "pure" is an aspiration rather than an invariant.

### The Leaky Adapter
Provider-specific knowledge appearing above the `providers/` directory — special-cased error handling, model-specific parameter adjustments, or protocol-aware message formatting in the orchestration layer. Each leak adds an implicit dependency that prevents provider substitution.

### The God Orchestrator
An orchestration module that accumulates business logic: message transformation, cost calculation, context management, UI decisions. It starts as "just wiring" and ends as the only module anyone needs to change for any feature, making all changes risky.

### The Flag-State Machine
Using boolean flags to implicitly represent what is actually a finite state machine. The legal combinations are nowhere documented, the illegal combinations are nowhere prevented, and the next person to add a state transition will get one of them wrong.

### The Bidirectional Dependency
Two modules that require each other, directly or through callbacks they were not explicitly given. This destroys the property that lets you verify one layer without holding the whole system in your head. If a callback needs to flow upward, it must be passed as an argument at the call site.
