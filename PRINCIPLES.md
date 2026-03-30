# PRINCIPLES

Timeless architectural and design principles for this AI-centric neovim plugin.
These principles are permanent. They survive every model generation, provider pivot, and API change.

---

## Cardinal Rule

The AI is a guest in the editor. The editor is never a guest in the AI.
The user opened neovim to edit text. The AI is consulted, never in control.
This asymmetry is non-negotiable and permanent.

---

## Neovim Alignment

Honour neovim's own philosophy. Fight it and the plugin becomes a foreign body. Align with it and the plugin becomes invisible — the highest compliment.

### Text Is the Universal Interface

- Chat output lives in buffers. Responses are text. Context is lines in a file.
- Every surface the user interacts with must support yank, search, motions, and operators.
- NEVER introduce custom rendering that bypasses buffer primitives.

### Composability Over Completeness

- Expose functions, commands, autocommands, and user-overridable keymaps.
- Let users wire the plugin into their own workflows (telescope, treesitter, etc.).
- Build small composable units, not monolithic features.

### Respect Modal Editing

- All interactions must feel native to normal, visual, and insert modes.
- The chat buffer must behave like a neovim buffer, not a web app in a terminal.

### Never Steal Focus

- All provider communication is async. NEVER block the editor loop.
- NEVER move the cursor without explicit user action.
- The user's flow state is the most expensive resource in the system.

---

## Architecture

### Hard Boundary: Plugin Logic vs Provider

The most important architectural decision. Build a strict abstraction between plugin logic and any AI provider.

```
[Chat UI / Buffer Layer]
        |
[Conversation Logic]    <-- This is the plugin. This is YOUR code.
        |
[Provider Adapter]      <-- Thin. Replaceable. Boring.
        |
[Bedrock | Ollama | Any future provider]
```

- The adapter accepts a standardized request and returns a standardized stream.
- Nothing provider-specific leaks above the adapter boundary.
- Models die. APIs mutate. Companies pivot. The adapter absorbs all of this.

### Separate by Rate of Change

Three layers, three rates of change:

| Layer | Changes when... | Rate |
|---|---|---|
| UI / Buffer management | Neovim changes | Rarely |
| Conversation / business logic | You add features | Occasionally |
| Provider integration | Someone else changes their API | Unpredictably |

RULE: A fast-changing layer must NEVER dictate the structure of a slow-changing layer.

### State Is a Liability

- Hold the minimum state necessary.
- Let the filesystem or simple serialization own persistent data, not in-memory structures that die with the session.
- Every piece of state held is state that must be synchronized, persisted, and debugged.

---

## Human-First, AI-Augmented

### Transparency Is Non-Negotiable

The user must ALWAYS be able to see:

1. What context is being sent to the model (files, lines, system prompt).
2. Which model is responding.
3. When a request is in flight and how to cancel it.

RULE: If the user cannot inspect the full prompt with a single command, the plugin is a black box. Black boxes erode trust permanently.

### Augment Understanding, Not Speed

- Speed is a side effect. The goal is augmented learning and understanding.
- If the plugin lets someone accept code they do not understand, it has failed.
- Design every interaction to encourage reading, evaluating, and learning.
- NEVER auto-apply generated content to a user's buffer without explicit consent.

### Intentional Friction Is a Feature

- A confirmation step before applying AI-generated changes is good design, not bad UX.
- The pause where the developer reads and evaluates is the entire point.
- Remove all unnecessary friction. Preserve all intentional friction that protects agency.

---

## Robustness

### The Network Is Hostile

- API calls fail. Streams disconnect mid-token. Timeouts happen. Rate limits hit.
- Handle all failures gracefully: no stack traces in chat buffers, no corrupted state, no silent failures.
- Show the user what happened in plain language. Let them retry.

### Never Corrupt the User's Work

This is a HARD RULE with ZERO exceptions:

- NEVER write to a buffer the user is editing without explicit action.
- NEVER modify a file on disk.
- NEVER interfere with undo history in a way the user cannot reverse.
- The user's code is their code. The plugin is a guest.

---

## Defaults and Configuration

### Sane Defaults, Total Configurability

- The plugin must work with zero configuration.
- Everything is overridable: keymaps, providers, model parameters, system prompts, buffer position.
- Neovim users will customize. Let them.

### Fail Loudly in Dev, Gracefully in Production

- Use `vim.validate`, assertions, and strict type checking during development.
- In the user's hands, catch errors and surface them humanely.
- The plugin must NEVER crash neovim.

### Documentation Is Interface Design

- If a feature needs a paragraph of explanation, the feature is too complex.
- `:help` docs are part of the product, not an afterthought.
- Write documentation as you code, not after.

---

## Meta-Principle

All principles above reduce to one idea:

**Respect the human on the other side of the screen.**

- Respect their attention: do not steal focus.
- Respect their intelligence: be transparent.
- Respect their autonomy: never act without consent.
- Respect their workflow: compose with their tools.
- Respect their time: work asynchronously.
- Respect their growth: make them think, not just accept.

The models will change. The providers will change. The APIs will change.
The human need for agency, understanding, and flow does not change.
