# psi architecture

This document describes the runtime shape `psi` is expected to satisfy.
It is a current-state and forward-state document only. Code and docs should
move toward this model; migration history and compatibility notes do not
belong here.

## Design rules

- Keep the host small. C exists for OS, terminal, process, filesystem, HTTP,
  and Lua embedding boundaries.
- Keep policy in Lua. Session orchestration, provider logic, rendering,
  commands, layout, and tool policy belong in `lua/psi/*.lua`.
- Keep execution single-threaded at the Lua boundary. One thread owns
  `lua_State`; no helper thread may call into Lua.
- Keep frontends thin. Print, REPL, and TUI are different I/O shells over the
  same runtime.
- Prefer append-only state. Sessions, tool events, and compaction artifacts
  should be recorded as durable facts rather than mutable snapshots.
- Favor explicit seams. If a behavior is host-dependent, expose a narrow
  primitive and keep the policy above it in Lua.
- Treat architecture docs as target behavior. New work should describe how the
  system should work, not how older code happened to work.

## Runtime layers

### 1. Host boundary in C

The C layer provides a narrow execution substrate:

- process bootstrap and CLI parsing
- Lua VM creation and registration of the `psi.*` host API
- append/read helpers for the in-memory session cache
- filesystem primitives
- shell/process primitives
- HTTP streaming primitives
- terminal primitives for `--tui`
- abort signaling

The C layer should not own agent policy, prompt construction, provider loops,
session semantics, rendering policy, or slash-command behavior.

### 2. Lua runtime

Lua owns the runtime model:

- top-level mode dispatch in `lua/psi/modes.lua`
- session loading, saving, projection, and metadata in `lua/psi/session.lua`
- provider loops in `lua/psi/anthropic.lua`, `lua/psi/openai_compat.lua`,
  `lua/psi/openrouter.lua`, and `lua/psi/ollama.lua`
- cooperative scheduling in `lua/psi/sched.lua`
- tool registry and built-in tool implementations
- prompt assembly, context shaping, render hooks, and event hooks
- TUI state, rendering, and key policy

Lua is the default place to implement features unless the feature must touch
the terminal, OS, or embedded VM boundary directly.

### 3. Frontends

Frontends consume the same runtime and differ only in presentation:

- `--print` emits a single rendered response
- `--agent` runs one streaming turn through the stdout renderer
- `--repl` loops on line input and reuses the same agent/session pipeline
- `--tui` renders a full-screen terminal UI through Lua-owned state

Frontends should not fork their own provider or session semantics.

## Execution model

### Single owner of Lua

`lua_State` has exactly one owner thread. All Lua code, render hooks, provider
loops, tool hooks, and TUI state transitions execute on that thread.

This rule is the core concurrency guarantee. It removes shared-memory races
inside Lua and turns runtime concurrency into explicit cooperative
interleaving.

### Helper threads and subprocesses

The runtime may use helper execution contexts for I/O:

- `src/core/http_async.c` performs streaming HTTP work behind a pollable handle
- `src/core/process.c` manages shell child processes behind a pollable handle

Those helpers communicate with Lua through byte buffers, status flags, and
poll functions exposed by C. They never run Lua callbacks and never mutate Lua
state directly.

### Cooperative scheduler

`lua/psi/sched.lua` is the scheduler for agent turns and concurrent tool work.

- `sched.run(fn, ...)` runs a turn inside a coroutine
- yield requests such as `http`, `proc`, `sleep`, and `tick` are resolved by
  the scheduler
- between resumes, the scheduler calls `psi.host_tick()` so the active host can
  keep making progress

In `--tui`, `psi.host_tick()` lets the UI keep pumping input and redraw while a
provider stream or shell process is in flight. In non-TUI modes, the same
coroutine logic runs without a UI loop.

### Concurrent tools

Providers may emit multiple tool calls in one assistant turn. The runtime runs
those tool calls concurrently through `sched.run_all(...)`.

Concurrency here means cooperative interleaving on the one Lua thread, plus any
underlying subprocess or HTTP activity driven by pollable handles. There are no
Lua data races, but there can be real-world side-effect races if two tools
touch the same external resource.

Current discipline:

- read/search/process style tools can run concurrently
- file mutation tools that know their target path should serialize that target
- tools with arbitrary side effects must provide their own serialization policy
  or accept the consequences of parallel execution

The runtime should preserve concurrency where it is safe and narrow it where
the side effects are ambiguous.

### Cancellation

Cancellation is modeled as a shared abort signal stored in the host context and
observed from Lua through `abort_check` / `psi.is_aborted()`.

- frontends trigger cancellation through host primitives
- provider loops poll the signal at safe boundaries
- async process and HTTP helpers honor the same signal

Cancellation must stop future work, preserve session consistency, and leave the
runtime in a state where the next turn can start normally.

## TUI architecture

### Ownership split

The full-screen TUI is Lua-owned.

Lua owns:

- transcript state
- input buffer and cursor state
- scroll state
- session replay into visible entries
- keybinding policy
- multiline wrapping policy
- status/footer content
- render passes and cursor placement decisions
- turn orchestration while the UI is active

C owns only the terminal boundary:

- `ncurses` bootstrap and teardown
- key normalization from terminal escape sequences to semantic keys
- line drawing primitives
- cursor visibility/placement primitives
- screen clear/refresh primitives
- terminal size queries
- suspend support

### TUI module boundaries

- `src/runtime/tui_mode.c` bootstraps ncurses and delegates to Lua mode
- `src/lua/vm.c` exposes the `psi.tui_*` host primitives
- `lua/psi/tui_runtime.lua` owns the runtime state machine for `--tui`
- `lua/psi/tui.lua` maps semantic keys to edit/navigation actions
- `lua/psi/tui_layout.lua` owns layout policy such as prefixes, footer text,
  and row caps

The intended rule is simple: C reports terminal facts and performs terminal
drawing; Lua decides what the interface means and what the screen should say.

## Sessions and lifecycle events

Sessions are append-only JSONL logs with typed records. The runtime uses them
as the durable source of truth for conversation state, tool activity,
compaction summaries, and session metadata.

Lifecycle guarantees:

- a loaded or freshly-created session emits one `session-start`
- a shutting-down frontend emits one `session-shutdown`
- every frontend should use the same lifecycle semantics

Turn/render guarantees:

- `before-turn` reflects the user prompt about to run
- `tool-call` and `tool-result` reflect concrete tool activity
- `after-turn["assistant-streamed"]` is true only when assistant text was
  actually observed during the turn

Extensions should be able to rely on those events without needing host-specific
special cases.

## Provider model

Provider modules implement a shared contract:

- accept user text, model choice, token limits, observer callbacks, and abort
  checks
- stream assistant text and reasoning deltas through the observer
- collect tool calls from the provider protocol
- dispatch tools through the shared tool runtime
- append durable session records
- return a final success flag plus assistant text

Provider code should stay unaware of frontend layout or terminal concerns. Its
job is turn execution and session-correct event emission.

## Tool system

Tools are registered in Lua and dispatched through a common registry.

The tool layer owns:

- schemas exposed to providers
- hookable dispatch (`before` / `after`)
- structured result records
- serialization for mutation-sensitive tools when the target is known
- live progress forwarding for long-running shell/process tools

The shell-facing tools should stream incremental progress without buffering the
same bytes repeatedly in Lua, while still producing a final structured tool
result for the session log.

## Extension surface

The primary extension API is the `psi.*` Lua surface plus the event and render
hook systems.

Extensions should be able to:

- subscribe to lifecycle and turn events
- add or wrap tools
- shape rendering output
- inspect embedded source/docs when needed
- customize prompts, layout policy, and context

Extensions should not need to patch C for runtime policy changes.

## Engineering direction

Near-term direction:

- keep the C codebase below 10k lines
- continue moving policy and orchestration upward into Lua
- keep the TUI Lua-owned, with C restricted to terminal primitives
- keep provider and tool concurrency explicit and reviewable
- add tests around event ordering, session lifecycle, and concurrent tool
  behavior whenever the runtime surface changes

The default question for new code should be: "Can this be expressed as Lua
policy on top of a narrow host primitive?" If the answer is yes, it belongs in
Lua.
