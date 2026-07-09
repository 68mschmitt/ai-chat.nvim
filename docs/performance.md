# Performance

**Thesis:** The only performance metric that matters is whether the user perceives the editor as responsive — and the primary threat to responsiveness is blocking the Neovim event loop.

*Perspectives: John Carmack (measure before assuming, latency is king, profile the hot path) and Ken Thompson (minimalism, every line is a liability, the fastest code is code that doesn't run). Carmack would instrument everything and optimize the measured bottleneck. Thompson would delete code until the problem disappeared. We follow both: measure first (Carmack), then delete (Thompson). Optimize only what measurement proves is slow.*

---

## Principles

### 1. Never block the editor event loop

Every provider call goes through `vim.system` which is non-blocking. Every UI update goes through `vim.schedule`. The user's cursor, motions, and editing commands must never wait for a network response, a JSON parse, or a buffer write. This is the hard constraint — all other performance concerns are secondary.

**Rationale:** A blocked editor feels broken. A slow response feels normal (users expect network latency). The user's flow state is the most expensive resource in the system. One 200ms freeze destroys more value than a 2-second TTFT.

**Violation:** Using `vim.system(cmd):wait()` in the send path. The `:wait()` call blocks until curl completes. The entire editor freezes. The health check module uses `:wait()` because it runs during `:checkhealth` (already a blocking operation) — this is the sole acceptable use.

### 2. Measure what matters: TTFT and event loop latency

Time-to-first-token (TTFT) is measured on every send via `uv.hrtime()` at send start and first chunk arrival. This is the metric users feel. Event loop latency — the time between a keypress and Neovim processing it — is the metric that determines whether the editor feels responsive during streaming.

**Rationale:** Unmeasured performance claims are fiction. The codebase already measures TTFT because it's the metric that most directly correlates with user-perceived responsiveness. If we later need to optimize streaming render performance, we'll instrument that too — but only when measurement shows it matters.

**Violation:** Optimizing JSON parse performance without measuring it. Token estimation uses `word_count * 1.33` — a trivial heuristic. Replacing it with tiktoken would add a dependency and CPU cost for ~10% more accuracy on a UI indicator. Not worth it until measurement proves the heuristic causes visible problems.

### 3. Approximate is fine when precision doesn't affect correctness

Token estimation uses word count × 1.33. Cost estimation uses per-model pricing tables. Neither is exact. Both are good enough for their purpose: UI indicators and budget awareness. Exactness would require external tokenizers or real-time API queries — costs that exceed the value of the precision gained.

**Rationale:** The purpose of the token count display is to give the user a sense of conversation size. The purpose of the cost display is to prevent surprise bills. Neither requires four decimal places of accuracy. The user needs to know "this conversation has used ~50K tokens" and "this session cost ~$0.12."

**Violation:** Adding a tiktoken Lua binding to get exact token counts. This adds a native dependency, increases startup time, and provides precision the user doesn't need. The heuristic is a feature, not a bug.

### 4. The fastest code is code that doesn't run

The spinner stops when no stream is active — zero overhead when idle. Provider preflight checks run once per session per provider, not on every send. The models registry loads from disk cache and refreshes asynchronously in the background. Config is frozen once and never re-validated until a `set()` call.

**Rationale:** Optimization by elimination is always superior to optimization by acceleration. A function that runs zero times is infinitely faster than a function that runs in zero nanoseconds. Before optimizing a hot path, ask whether the path needs to be hot.

**Violation:** Running `config.validate()` on every send "just to be safe." Validation runs once during `setup()` and once after each `config.set()` call. If the config was valid then, it's valid now — it's frozen.

### 5. Lazy-load everything the user hasn't asked for

The plugin registers commands and keymaps during `setup()` but doesn't create buffers, windows, or network connections until the user opens the chat panel. Provider modules are loaded on first use via `providers.get()`. The models registry loads from disk cache synchronously and refreshes from the network asynchronously.

**Rationale:** Most Neovim sessions never open the chat panel. The plugin's startup cost should be proportional to what it actually does during setup: register commands, define highlights, load cached state. Everything else waits.

**Violation:** Fetching the models.dev registry synchronously during `setup()`. This adds network latency to Neovim startup for data that isn't needed until the user opens a model picker. The actual code calls `M.ensure()` which loads from disk cache (instant) and kicks off a background refresh (non-blocking).

### 6. Auto-scroll respects user position

During streaming, the chat buffer auto-scrolls to follow new content — but only if the user's cursor is near the bottom of the buffer. If the user has scrolled up to read earlier content, auto-scroll is suppressed. The threshold is configurable and the check is O(1).

**Rationale:** Auto-scroll that fights the user's scroll position is the most common UX complaint in streaming chat interfaces. The check is trivial: compare cursor line to buffer line count. The cost is one comparison per chunk. The value is preserving the user's reading position.

**Violation:** Always scrolling to the bottom on every chunk, regardless of cursor position. The user scrolls up to re-read a code block, the next chunk yanks them back to the bottom. This is a UX failure that no amount of performance optimization can fix.

### 7. Delete before you optimize

When a module feels slow, the first question is: what can be removed? Can the computation be skipped entirely? Can it run less often? Can the data structure be smaller? Only after elimination is exhausted should you consider making the remaining code faster.

**Rationale:** Optimization adds complexity. Deletion removes it. A function that's been deleted cannot be slow, cannot have bugs, and cannot confuse the next reader. The token estimator is a one-liner because we deleted the accurate version — the approximation is fast enough AND simpler.

**Violation:** Adding a caching layer to speed up `conversation.build_provider_messages()`. The function runs once per send. Caching it saves ~1ms on a path that includes a multi-second network round trip. The cache adds complexity (invalidation logic, memory) for zero perceptible benefit.

---

## Tradeoffs We Accept

| Tradeoff | Accepted cost | Gained benefit |
|---|---|---|
| `vim.deepcopy` on every `conversation.get()` | ~0.1ms copy per call | Immutability guarantee — no shared mutable state bugs |
| Heuristic token estimation | ~10% inaccuracy | Zero external dependencies, sub-microsecond computation |
| Temp file for curl request body | Disk write per send | Avoids shell escaping bugs with large JSON payloads |
| Full conversation JSON in history files | Disk space (~KB per conversation) | Simple read/write, no partial update logic, atomic writes |
| Separate JSON file per conversation | Many small files | O(1) load by ID, atomic writes, no index corruption cascades |

## Tradeoffs We Reject

| Rejected tradeoff | Why |
|---|---|
| Blocking curl calls for "simpler" code | Violates Principle 1. No amount of code simplification justifies freezing the editor. |
| Exact tokenization via native bindings | Adds a dependency, a build step, and startup cost for a UI indicator. |
| In-memory conversation cache | Adds invalidation complexity for unmeasured performance gain on a path dominated by network latency. |
| Debouncing chunk rendering | Adds latency to the streaming display. Users perceive token-by-token rendering as responsiveness. Batching feels sluggish. |
| Background thread for JSON parsing | Neovim's Lua runtime is single-threaded. The "threading" would be a Lua coroutine adding complexity without parallelism. `vim.json.decode` is C-backed and fast enough. |

---

## Violations

### V1: Blocking the event loop

Any synchronous operation that takes >50ms in the interactive path. This includes synchronous HTTP calls, synchronous file reads of large files, and synchronous computation on large data. All of these must be async (via `vim.system`, `vim.schedule`, or `vim.uv` timers).

### V2: Optimizing without measurement

Adding complexity (caches, pools, batching, threading) without first measuring the bottleneck with `uv.hrtime()` or Neovim's built-in profiling. The optimization may target a path that takes 0.1% of wall time while the actual bottleneck is elsewhere.

### V3: Adding dependencies for marginal gains

Introducing a new external dependency (native module, luarocks package) to improve performance by a margin the user cannot perceive. The dependency has ongoing costs: build complexity, platform compatibility, update burden. The performance gain must be dramatic and user-perceptible to justify it.

### V4: Fighting the user

Any behavior that overrides the user's explicit action for "performance" or "convenience" reasons. Auto-scroll that ignores cursor position. Debouncing that delays visible feedback. Lazy loading that makes the first interaction visibly slow. The user's intent takes priority over the plugin's optimization strategy.
