# psi architecture

This document describes the runtime model `psi` is expected to follow. It covers
current behavior and intended direction. Migration notes and compatibility
history belong in issue threads or port-status docs, not here.

## Design rules

- Keep the host small. C exists for OS, terminal, process, filesystem, HTTP, and
  Lua embedding boundaries.
- Keep policy in Lua. Session orchestration, provider logic, rendering,
  commands, layout, and tool policy belong under `lua/psi/`.
- Keep execution single-threaded at the Lua boundary. One thread owns
  `lua_State`; no helper thread may call into Lua.
- Keep frontends thin. Print, REPL, and TUI are different I/O shells over the
  same runtime.
- Prefer append-only state. Record sessions, tool events, and compaction
  artifacts as durable facts rather than mutable snapshots.
- Make host-dependent behavior explicit. Expose a narrow primitive and keep the
  policy above it in Lua.
- Gate host-dependent capabilities. Optional OS, terminal, and library-backed
  behavior should compile out cleanly and report availability through
  `psi.runtime_info()`.
- Treat architecture docs as target behavior. New work should describe the model
  the system is moving toward, not preserve old implementation notes.

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

Host primitives are registered in `src/lua/vm.c` via `PSI_REG_DOC`,
which attaches a one-line docstring queryable from inside psi. The
running agent enumerates and describes them itself:

```
psi> /apropos psi.                # all host primitives by name
psi> /describe psi.read_file_slice
psi> /describe psi.tool_call
```

CLI flags accepted by the entry point are kept in markdown because they are
useful before the binary is installed. Regenerate this table from
`src/runtime/cli.c` with `make docs`:

<!-- @generated:cli-options -->
| Flag | Argument | Description |
|---|---|---|
| `--agent` | `TEXT` | run a single coding-agent turn |
| `--boot` | `FILE` | override the Lua bootstrap file |
| `--chat` | — | use the chat-style TUI (transcript flows into terminal scrollback) |
| `--compact` | `N` | compact the current session, keeping the most recent N messages |
| `-c`, `--continue` | — | continue the most recent session for the current directory |
| `--eval` | `EXPR` | evaluate a Lua expression and print the result |
| `-h`, `--help` | — | show help |
| `--max-tokens` | `N` | max output tokens for --agent |
| `--model` | `MODEL` | model to use with --agent |
| `--no-context-files` | — | disable AGENTS.md and CLAUDE.md discovery (alias -nc) |
| `--no-extensions` | — | disable user extension discovery |
| `--no-prompt-templates` | — | disable prompt template discovery (alias -np) |
| `--no-trust` | — | never load this directory's .psi resources |
| `--print` | `TEXT` | run the bootstrap print-mode handler |
| `--prompt-template` | `FILE` | load an extra prompt template file or directory |
| `--repl` | — | run the interactive line editor shell |
| `-r`, `--resume` | — | pick a session to resume (TUI picker) |
| `--session` | `FILE` | load and save a JSONL session file |
| `--system-prompt` | — | print the default coding-agent system prompt |
| `--thinking` | `LEVEL` | thinking level: off, minimal, low, medium, high, xhigh |
| `--trust` | — | trust this directory's .psi resources without prompting |
| `--tui` | — | run the inline interactive TUI |
| `--version` | — | show version |
<!-- @end -->

### 2. Lua runtime

Lua owns the runtime model:

- top-level mode dispatch in `lua/psi/modes.lua`
- shared frontend lifecycle in `lua/psi/agent_session_runtime.lua`
- session loading, saving, projection, and metadata in `lua/psi/session_manager.lua`
- provider loops in `lua/psi/providers/anthropic.lua`,
  `lua/psi/providers/openai_compat.lua`, `lua/psi/providers/openrouter.lua`,
  `lua/psi/providers/openai_codex.lua`, and `lua/psi/providers/ollama.lua`
- cooperative scheduling in `lua/psi/sched.lua`
- tool registry and built-in tool implementations
- prompt assembly, context shaping, render hooks, and event hooks
- TUI state, rendering, and key policy

Lua is the default place for new features unless the feature must touch the
terminal, OS, or embedded VM boundary directly.

Lua policy must not assume every host capability is present. It should check
`psi.runtime_info()` or a module-level capability wrapper and degrade cleanly
when a feature is disabled.

### 3. Frontends

Frontends consume the same runtime and differ only in presentation:

- `--print` emits a single rendered response
- `--agent` runs one streaming turn through the stdout renderer
- `--repl` loops on line input and reuses the same agent/session pipeline
- `--tui` renders an inline terminal UI through Lua-owned state

Frontends should not fork their own provider or session semantics.

## Execution model

### Single owner of Lua

`lua_State` has exactly one owner thread. All Lua code, render hooks, provider
loops, tool hooks, and TUI state transitions execute on that thread.

This rule is the concurrency guarantee. It removes shared-memory races inside
Lua and turns runtime concurrency into explicit cooperative interleaving.

### Helper threads and subprocesses

The runtime may use helper contexts for I/O:

- `src/core/http_async.c` performs streaming HTTP work behind a pollable handle
- `src/core/process.c` manages shell child processes behind a pollable handle

Those helpers communicate with Lua through byte buffers, status flags, and poll
functions exposed by C. They never run Lua callbacks or mutate Lua state
directly.

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

Concurrency here means cooperative interleaving on the one Lua thread, plus
subprocess or HTTP activity driven by pollable handles. Lua data races are off
the table, but external side effects can still race if two tools touch the same
resource.

`sched.run_all(..., { on_done = fn })` reports each tool as it completes, so the
TUI can update individual tool panels without waiting for the slowest sibling.
Session persistence still writes the final tool-result messages after the batch
settles, preserving the existing provider-loop transcript shape.

Current rules:

- read/search/process style tools can run concurrently
- file mutation tools that know their target path should serialize that target
- tools with arbitrary side effects must provide their own serialization policy
  or accept parallel execution

The runtime should preserve concurrency where it is safe and narrow it where
the side effects are ambiguous.

### Cancellation

Cancellation is a shared abort signal stored in the host context and observed
from Lua through `abort_check` / `psi.is_aborted()`.

- frontends trigger cancellation through host primitives
- provider loops poll the signal at safe boundaries
- async process and HTTP helpers honor the same signal

Cancellation must stop future work, preserve session consistency, and leave the
runtime in a state where the next turn can start normally.

## TUI architecture

### Ownership split

The TUI is Lua-owned. It defaults to an inline raw-mode terminal surface: the
normal screen buffer and terminal scrollback stay in use while the TUI renderer
updates the visible viewport with ANSI line frames. Alt-screen mode remains
available through `PSI_TUI_ALT_SCREEN=1`.

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
- a private terminal descriptor used only by TUI rendering
- whole-lifetime stdout/stderr quarantine for unstructured writes
- key normalization from terminal escape sequences to semantic keys
- ANSI/OSC stripping, UTF-8 cluster measurement, cell-width clipping,
  padding, and ANSI-aware wrapping primitives
- legacy absolute line/cursor primitives used by contained alt-screen surfaces
- terminal size queries
- suspend support

### TUI module boundaries

- `src/runtime/tui_mode.c` switches the terminal into raw mode and delegates to Lua mode
  without entering the alternate screen by default
- `src/lua/vm.c` exposes the `psi.tui_*` host primitives
- `lua/psi/tui_runtime.lua` owns the runtime state machine for `--tui`
- `lua/psi/tui_app.lua` owns the pi-style TUI controller layer: root
  children, focus, render requests, overlay layout, and overlay compositing
- `lua/psi/tui_renderer.lua` owns logical frame normalization, cursor extraction,
  terminal-relative cursor accounting, and full/differential frame rendering
- `lua/psi/notice.lua` owns structured operational diagnostics and the explicit
  active-frontend sink
- `lua/psi/tui_component.lua` and `lua/psi/tui_components/*` own composable
  layout/rendering surfaces such as transcript markdown and chrome
- `lua/psi/tui_status.lua` exposes TUI hook/status/key APIs, while
  `lua/psi/tui_runtime.lua` owns the runtime state machine and default
  edit/navigation actions
- `lua/psi/tui_layout.lua` owns layout policy such as prefixes, footer text,
  and row caps

The rule is simple: one renderer owns terminal bytes while active. C reports
terminal facts, implements terminal text math, and enforces that ownership.
Lua decides what the interface means and what the screen should say.

### TUI rendering path

Lua selects the TUI renderer at startup from host/runtime capabilities.
`lua/psi/tui_runtime.lua` derives `ansi`, `color`, and `raw_ansi` from
`psi.runtime_info()`, `TERM`, `NO_COLOR`, and explicit override environment
variables.

Rendering policy:

- The runtime mutates persistent components and asks `tui_app` for one final
  composed frame. Overlays are rendered separately, positioned by anchor or
  row/column options, and spliced into the base frame by terminal columns.
- The first inline paint anchors at the terminal's current cursor. Later paints
  use relative movement from the renderer's tracked hardware row, so startup
  output stays above the live region and terminal scrolling remains natural.
- Complete output batches use synchronized-output markers. Frame lines stay one
  cell narrower than the terminal to avoid pending-wrap cursor drift.
- Lua owns the previous-frame cache and emits only changed logical rows.
- Idle TUI and resume-picker loops sample terminal dimensions every 200 ms;
  active turns sample them at scheduler ticks. A size change invalidates the
  component cache and forces a full frame at the new width and height.
- Fall back to plain-text frames when ANSI or color is disabled by the
  runtime policy.

Operational messages use `psi.notice`. Before the TUI state exists, its
explicit sink buffers a bounded FIFO. Once attached, notices become transcript
entries and only mark the UI dirty; the event loop coalesces repaint work.
Notices emitted during a mutable streaming entry wait until that entry is
finished so chat-style scrollback never commits a still-changing entry.

Unexpected direct stdout/stderr writes are not renderer input. While the TUI
owns the terminal, the host redirects them to the protected state debug log.
Suspend and external-editor boundaries release stdio and raw mode together,
then reclaim them and force a cursor-relative repaint on return.

C owns only the low-level terminal effects. The Lua TUI is ANSI-terminal
backed, so a no-ANSI build disables TUI support rather than exposing a
frontend that still writes escape bytes.

Runtime overrides:

- `PSI_ANSI=0|1` forces Lua's ANSI rendering policy within compiled support.
- `PSI_COLOR=0|1` forces Lua's color rendering policy within compiled support.
- `PSI_TUI_RAW_ANSI=0|1` forces raw ANSI TUI line drawing within compiled and
  terminal support.
- `PSI_TUI_ALT_SCREEN=1` restores the old alternate-screen + mouse-capture
  terminal boundary.
- `PSI_TUI_FULLSCREEN=1` or `PSI_TUI_INLINE_MAX_ROWS=<n>` controls the inline
  frame viewport. Prompt-height policy still derives from the physical terminal;
  frame mode then caps the prompt to the rows available in that viewport.
- `PSI_HARDWARE_CURSOR=0` falls back to the Lua-drawn prompt cursor.
- `NO_COLOR=1` disables color rendering.

### TUI availability

The TUI is an optional host capability.

- `TUI=1` compiles the ANSI inline TUI frontend and the backing
  `psi.tui_*` primitives
- `TUI=0` keeps the rest of the runtime buildable without terminal raw-mode support; `--tui`
  exits with a clear error
- `ANSI=0` implies `TUI=0`, because the Lua TUI backend has no non-ANSI
  renderer
- even when compiled in, `psi.tui_*` primitives are guarded so non-TUI modes
  cannot accidentally call terminal operations before the TUI is active

Lua-owned TUI code should treat the host terminal as a capability, not a global
assumption.

### TUI extension hooks

Built-in Vim-style modal editing is installed as a Lua extension through the
same `psi.tui.register_key_handler` and `psi.tui.register_status_hook` APIs
available to user extensions. C normalizes terminal input to semantic key ids;
Lua chooses whether a key edits text, switches editor mode, scrolls the
transcript, updates the status bar, or falls through to the default policy.

`/reload` resets bundled TUI extension state, clears TUI key, status, and
clipboard hooks, reloads user extensions, and then runs TUI startup hooks. That
keeps repeated reloads idempotent while letting settings-gated extensions, such
as bundled Vim modal editing and OSC 52 clipboard yanks, reinstall the hooks
their current configuration requires.

### ANSI and color

ANSI styling is also capability-driven.

- `ANSI=1` allows Lua renderers to emit SGR styling
- `ANSI=0` makes `psi.ansi` return plain text for styled content and disables
  the ANSI-backed TUI
- `COLOR=1` enables color SGR emission
- `COLOR=0` disables color while still allowing non-color styles such as bold
  or dim when ANSI support is present

Render helpers should go through `lua/psi/ansi.lua` instead of hard-coding
escape sequences. That gives dumb terminals, no-color environments, CI logs,
and small ports the same rendering policy.

## Portability and feature gates

Build-time feature gates are part of the host boundary. They let small ports or
constrained environments build a useful `psi` without carrying every POSIX or
terminal dependency.

Current gates:

- `TUI`: inline ANSI frontend and `psi.tui_*` host primitives
- `ANSI`: ANSI SGR emission and parsing
- `COLOR`: color SGR emission
- `MCP`: low-level stdio process primitives used by protocol clients
  (`psi.process_begin_stdio_argv`, `psi.process_try_write`, and related
  helpers). This is not a bundled MCP bridge.
- `REPL_EDITLINE`: libedit-backed REPL input/history; falls back to plain
  `fgets` input when disabled

Every feature-gate combination must compile. `make check-build-configs`
builds the complete `TUI` / `ANSI` / `COLOR` / `REPL_EDITLINE` matrix into
isolated build directories and should be run whenever C preprocessor guards
or optional dependencies change.

Rules for new gates:

- the Makefile flag should map to a `PSI_ENABLE_*` C define
- unavailable dependencies should be absent from compile and link flags
- C should return a clear error or provide a small fallback when the feature is
  disabled
- Lua should discover availability through `psi.runtime_info()` and degrade
  policy rather than branching on platform names

Use the same pattern for future optional boundaries such as network, process
tools, filesystem persistence, or embedded-asset compression.

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

### Agent runtime facade

`lua/psi/agent_session.lua` owns provider/model state and the turn,
side-question, compaction, and tree operations. A separate small
`lua/psi/agent_session_runtime.lua` facade owns the lifecycle common to print,
agent, REPL, TUI, compact, and future RPC frontends:

- bootstrap, session-id resolution, continue, and resume selection
- one `session-start` per loaded or newly-created session
- observer composition and streamed-assistant tracking around a turn
- saving after turns and compaction
- shutdown/start ordering when replacing a session
- one final `session-shutdown` when the frontend exits

Frontends still own their picker, rendering callbacks, input loops, status
messages, and error presentation. This follows the responsibility split of
pi-mono's current `AgentSessionRuntime` without copying its service graph or
moving policy into C.

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

The primary extension API is the `psi.*` Lua surface plus event and render
hooks.

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

For new code, ask: "Can this be expressed as Lua policy on top of a narrow host
primitive?" If yes, it belongs in Lua.
