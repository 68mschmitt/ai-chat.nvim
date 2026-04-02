# Performance

**Thesis:** In a system where the bottleneck is network latency and model inference, performance discipline means never blocking the editor, measuring before optimizing, and refusing to add complexity for gains the user cannot perceive.

---

## Principles

### 1. Never block the main loop — everything else is negotiable

**Rule:** In Neovim's single-threaded event loop, one synchronous stall of 50ms is worse than a thousand 0.01ms inefficiencies. The user is editing code in another buffer. A 50ms hitch means a dropped keystroke or a visible cursor stutter. All I/O, network calls, and heavy computation must be async or deferred.

**Rationale:** The streaming chunk path runs in ~0.1ms. Network + model TTFT is 500-2000ms. You have orders of magnitude of headroom on the local processing side. But a single synchronous disk read on the main loop erases all of that headroom instantly.

**Violation:** `store.list()` reads and JSON-decodes every conversation file synchronously. 200 saved conversations × 50KB each = 10MB of synchronous disk I/O + JSON parsing. The history browser freezes the editor. The fix: maintain a lightweight index file (id, title, timestamp per conversation) that gets appended on save, so `list()` never opens conversation files.

---

### 2. Measure from the user's perspective — time-to-first-visible-token, not internal throughput

**Rule:** The latency that matters is: user hits send → first token appears in the buffer. Measure this with a timestamp at the top of `pipeline.send()` and another in the first `on_chunk` invocation. If your overhead exceeds 50ms, something is wrong. If it is under 50ms, stop optimizing the send path.

**Rationale:** When the end-to-end time is 1200ms and 1180ms is network + model inference, optimizing the 20ms of local overhead is not a performance improvement — it is a waste of engineering time that could be spent on things the user can perceive.

**Violation:** Someone profiles, finds `vim.json.encode` takes 2ms for a large message array, and spends a day implementing incremental JSON encoding. The actual TTFT is 1.2 seconds. The 2ms was never the problem. Always measure end-to-end first. Only decompose if end-to-end is bad.

---

### 3. Accept the deep copies in conversation.get() — reject adding more of them carelessly

**Rule:** `conversation.get()` returns `vim.deepcopy(state)`. This is correct and must be preserved. For a 50-message conversation, deep copy costs ~0.1-0.5ms. It is called a handful of times per user action. The cost is nothing. The alternative — mutable references across async callbacks — produces action-at-a-distance bugs that cost hours to diagnose.

**Rationale:** If a callback in `on_done` holds a reference across a `vim.schedule` boundary, and another `vim.schedule` fires `clear()` in between, you are writing a stale message into a cleared conversation. The deep copy prevents this entire class of defect.

**Violation:** Someone profiles, sees `deepcopy` in the flamegraph, "optimizes" it by returning `state` directly with a comment "callers must not mutate." Three weeks later, a race condition between `on_done` and `clear()` causes ghost messages. The deep copy costs microseconds. The bug costs hours. Keep the copies.

---

### 4. Batch work to the natural rate of the input, not the theoretical rate of the output

**Rule:** SSE chunks arrive every 20-80ms. The render path runs in ~0.1ms. You have 100x headroom. Do not optimize the per-chunk path now, but design it so batching is trivial to add later. Avoid adding O(n) operations that run on every chunk — accumulate and process on `on_done` instead.

**Rationale:** 200 chunks × 1 `vim.schedule` each = 200 main-loop interruptions during a response. This is fine today. But if you add per-chunk syntax highlighting, per-chunk token counting, or per-chunk cost estimation, each O(n) operation turns the response lifecycle into O(n²).

**Violation:** Adding a `tokens.estimate()` call inside `render.append()` to show a running token count. The gmatch loop runs over the full accumulated text on every chunk, turning an O(n) operation into O(n²) over the response. If you want a running count, count the delta per chunk. Better yet, show the count only on `on_done`.

---

### 5. One fact, one place — duplicated data sources are a maintenance cost disguised as a performance optimization

**Rule:** Context windows hardcoded in `conversation.lua` AND fetched from models.dev in `models.lua` is two sources of truth. Pricing in `costs.lua` AND in `models.lua` is two sources of truth. Pick one authoritative source with a fallback chain. The hardcoded tables should be the fallback inside the registry, not a parallel system consulted independently.

**Rationale:** Two sources of truth that drift silently are worse than one source that is sometimes stale. When Anthropic ships a new model, someone updates one table and forgets the other. Context truncation silently uses the wrong window for weeks.

**Violation:** A new model is added to `models.lua`'s fallback table but not to `conversation.lua`'s `model_context_windows`. Truncation uses the provider default (200K) instead of the model's actual window (32K). Messages that should be truncated are sent in full. The API rejects them or produces degraded results.

---

### 6. Do disk I/O at transition boundaries, never on the hot path

**Rule:** The plugin's rhythm has clear phases: setup (once), send (once per user action), streaming (many chunks), done (once per response), browse (once per user action). Disk I/O belongs at the transitions. The streaming chunk loop must never touch disk.

**Rationale:** Writing history on `on_done` is correct — it happens once per response at a natural pause point. The user just saw the response complete; a few milliseconds of disk write is invisible. During streaming, even 10ms of synchronous disk I/O every 10th chunk is perceptible as stutter.

**Violation:** An "auto-save draft" feature writes the partial response to disk every N chunks for crash recovery. Every 10th chunk triggers synchronous `vim.fn.writefile`. On a network filesystem, that is 10-50ms of main-loop blocking, 20 times during a response. If crash recovery is needed, write once on error (the failure path), not during streaming.

---

### 7. Never over-engineer small lookups — linear scans over small collections beat cached lookups

**Rule:** A typical Neovim session has 2-8 windows. Iterating them and calling `nvim_win_get_buf` on each is ~0.01ms. Do not cache the window ID to skip the iteration — caching introduces invalidation complexity for zero measurable benefit. The threshold for caching is ~100+ items; below that, iterate.

**Rationale:** The auto-scroll logic iterates all windows to find the one showing the chat buffer. This is correct. Caching the window ID would require invalidation hooks on `WinClosed`, `BufWinEnter`, `BufWinLeave` — 40 lines of event handler code and a new class of stale-state bugs, all to save 0.01ms.

**Violation:** Someone adds a `_chat_win_id` cache, set on panel open. The user does `:split` and moves the chat buffer to a different window. Auto-scroll breaks because the cached ID points to the old window. The fix requires more invalidation hooks. The original iteration had no bug because it had no state.

---

## Accepted Tradeoffs

| We Accept | We Reject |
|---|---|
| `vim.deepcopy` on conversation state (correctness > microseconds) | Deep copying config on every access (read-mostly, mutated only via `set()`) |
| Per-chunk `vim.schedule` + modifiable toggle (well within budget) | Any synchronous disk I/O on the chunk-processing path |
| `word_count × 1.33` token estimation (avoids a dependency for a display-only number) | Loading a tokenizer library for precise counts that are shown in a UI indicator |
| O(n²) string concat in SSE parser at current response sizes (<4K chunks) | O(n²) on any path that could handle 100K+ tokens without refactoring |
| Linear window scan for auto-scroll (N < 10 always) | Cached state that requires invalidation machinery for negligible gain |
| Full JSON rewrite on history save (infrequent, at transition boundary) | Full JSON parse of all history files for browse listing (needs an index) |

---

## Anti-Patterns

### The Premature Optimization
Profiling internal function calls and optimizing 2ms operations while the end-to-end latency is dominated by 1200ms of network time. Always measure the user-visible metric first. Only decompose if the total is bad.

### The Main-Loop Blocker
Synchronous disk I/O, synchronous network calls, or O(n) computation on large data sets executed on the Neovim event loop. One 50ms stall is more damaging than a hundred 0.01ms inefficiencies because the user perceives it as the editor being broken, not the plugin being slow.

### The Correctness-for-Speed Trade
Removing deep copies, skipping buffer validity checks, or eliminating the modifiable flag toggle to save microseconds. These protections prevent classes of bugs that are far more expensive to diagnose than the cycles they cost. Performance work that undermines correctness invariants is not an optimization — it is a regression with a delayed fuse.

### The Quadratic Accumulator
An O(n) operation inside a per-chunk callback that processes the full accumulated content on every invocation. Token counting, syntax highlighting, or cost estimation over the complete response text turns the streaming lifecycle from O(n) to O(n²). Process deltas per chunk; process totals on completion.

### The Stale Cache
A cached value (window ID, buffer number, model metadata) introduced to skip a cheap lookup, requiring invalidation hooks that are more complex and more bug-prone than the original lookup. Below ~100 items, iteration without state is both faster and safer than caching with invalidation.
