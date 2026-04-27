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
- Gate host-dependent capabilities. Optional OS, terminal, and library-backed
  behavior should compile out cleanly and report availability through
  `psi.runtime_info()`.
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
- terminal primitives for `--tui` when TUI support is compiled in
- line editing through libedit when available, with a plain input fallback
- ANSI/style/color interpretation when the active renderer supports it
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

Lua policy must not assume that every host capability is present. It should
check `psi.runtime_info()` or a module-level capability wrapper and degrade
cleanly when a feature is disabled.

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

- raw terminal bootstrap and teardown
- key normalization from terminal escape sequences to semantic keys
- line drawing primitives
- cursor visibility/placement primitives
- screen clear/refresh primitives
- terminal size queries
- suspend support

### TUI module boundaries

- `src/runtime/tui_mode.c` switches the terminal into raw mode and delegates to Lua mode
- `src/lua/vm.c` exposes the `psi.tui_*` host primitives
- `lua/psi/tui_runtime.lua` owns the runtime state machine for `--tui`
- `lua/psi/tui.lua` maps semantic keys to edit/navigation actions
- `lua/psi/tui_layout.lua` owns layout policy such as prefixes, footer text,
  and row caps

The intended rule is simple: C reports terminal facts and writes terminal
bytes; Lua decides what the interface means and what the screen should say.

### TUI rendering path

The TUI renderer is selected by Lua at startup from host/runtime capabilities.
`lua/psi/tui_runtime.lua` derives `ansi`, `color`, and `raw_ansi` from
`psi.runtime_info()`, `TERM`, `NO_COLOR`, and explicit override environment
variables.

Rendering policy:

- Use raw ANSI line drawing when ANSI is compiled in, the terminal is not
  `dumb`, and `psi.tui_draw_raw_line` is available.
- Fall back to plain-text frames when ANSI or color is disabled by the
  runtime policy.

C owns only the low-level terminal effects. The Lua TUI is ANSI-terminal
backed, so a no-ANSI build disables TUI support rather than exposing a
frontend that still writes escape bytes.

Runtime overrides:

- `PSI_ANSI=0|1` forces Lua's ANSI rendering policy within compiled support.
- `PSI_COLOR=0|1` forces Lua's color rendering policy within compiled support.
- `PSI_TUI_RAW_ANSI=0|1` forces raw ANSI TUI line drawing within compiled and
  terminal support.
- `NO_COLOR=1` disables color rendering.

### TUI availability

The TUI is an optional host capability.

- `TUI=1` compiles the ANSI full-screen frontend and the backing
  `psi.tui_*` primitives
- `TUI=0` keeps the rest of the runtime buildable without terminal raw-mode support; `--tui`
  exits with a clear error
- `ANSI=0` implies `TUI=0`, because the Lua TUI backend has no non-ANSI
  renderer
- even when compiled in, `psi.tui_*` primitives are guarded so non-TUI modes
  cannot accidentally call terminal operations before the TUI is active

Lua-owned TUI code should treat the host terminal as a capability, not as a
global assumption.

### TUI extension hooks

Built-in Vim-style modal editing is installed as a Lua extension through the
same `psi.tui.register_key_handler` and `psi.tui.register_status_hook` APIs
available to user extensions. C normalizes terminal input to semantic key ids;
Lua chooses whether a key edits text, switches editor mode, scrolls the
transcript, updates the status bar, or falls through to the default policy.

`/reload` clears TUI key and status hooks, reinstalls built-in extensions, and
then reloads user extensions. That keeps repeated reloads idempotent instead
of stacking duplicate modal key handlers or status snippets.

### ANSI and color

ANSI styling is also capability-driven.

- `ANSI=1` allows Lua renderers to emit SGR styling
- `ANSI=0` makes `psi.ansi` return plain text for styled content and disables
  the ANSI-backed TUI
- `COLOR=1` enables color SGR emission
- `COLOR=0` disables color while still allowing non-color styles such as bold
  or dim when ANSI support is present

Render helpers should go through `lua/psi/ansi.lua` instead of hard-coding
escape sequences. This lets dumb terminals, no-color environments, CI logs,
and small ports all share the same rendering policy.

## Portability and feature gates

Build-time feature gates are part of the host boundary. They let small ports
or constrained environments build a useful `psi` without carrying every POSIX
or terminal dependency.

Current gates:

- `TUI`: full-screen ANSI frontend and `psi.tui_*` host primitives
- `ANSI`: ANSI SGR emission and parsing
- `COLOR`: color SGR emission
- `REPL_EDITLINE`: libedit-backed REPL input/history; falls back to plain
  `fgets` input when disabled

Every feature-gate combination must compile. `make check-build-configs`
builds the complete `TUI` / `ANSI` / `COLOR` / `REPL_EDITLINE` matrix into
isolated build directories and should be run whenever C preprocessor guards
or optional dependencies change.

The architectural rule for new gates:

- the Makefile flag should map to a `PSI_ENABLE_*` C define
- unavailable dependencies should be absent from compile and link flags
- C should return a clear error or provide a small fallback when the feature is
  disabled
- Lua should discover availability through `psi.runtime_info()` and degrade
  policy rather than branching on platform names

This pattern should be reused for future optional boundaries such as network,
process tools, filesystem persistence, or embedded-asset compression.

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

Tools are registered in Lua and dispatched through a common registry. Built-in
tools live as one module per tool under `lua/psi/tools/`; `lua/psi/tools.lua`
only wires those modules into the registry and re-exports the registry surface.

The tool layer owns:

- schemas exposed to providers
- hookable dispatch (`before` / `after`)
- structured result records
- serialization for mutation-sensitive tools when the target is known
- portable path resolution and filesystem helpers for read/write/listing tools
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
