# psi architecture

## 1. goals

`psi` should preserve the useful parts of `pi`'s harness model while removing
the TypeScript-first assumptions from the implementation.

Primary goals:

- keep the harness minimal and inspectable
- make the host runtime portable C89
- make Lua the first extension surface
- keep host primitives in C and policy/session shape in Lua
- make user customization cheap and progressive
- support both old and modern toolchains
- use Nix flakes for reproducible builds and dev shells

## 2. non-goals

The first implementation slice is not trying to ship all of `pi`.

Not in the first milestone:

- full interactive TUI parity
- package manager parity with npm and git package loading
- multi-provider OAuth support
- rich extension widgets
- subagents
- browser integrations

These are possible later, but they are not structural prerequisites.

## 3. reference concepts from pi

The `pi-mono` codebase suggests a few ideas worth preserving exactly at the
architectural level:

- one central session/runtime object
- tree-based session history, not flat transcripts
- a small built-in tool vocabulary
- multiple frontends over the same core
- summaries as first-class session artifacts
- progressive disclosure for skills and project context

In `psi`, those ideas stay. The implementation substrate changes.

## 4. top-level layering

`psi` is split into five layers.

### 4.1 host core

The host core is written in C89 and owns:

- memory management helpers
- strings and collections
- the small in-memory message array
- filesystem/process/HTTP primitives
- Lua VM embedding
- runtime configuration

The host core is not authoritative for agent policy. It provides portable
primitives and a simple session backing store; Lua owns the durable session
schema, provider routing, tool registry, and prompt/context projections.

### 4.2 runtime layer

The runtime layer assembles the host core into actual modes:

- print mode
- interactive mode
- TUI mode
- RPC mode

Each mode is only an I/O shell around the same session object.

### 4.3 Lua VM layer

Lua 5.4 is embedded as the extension runtime.

Lua is used for:

- the tool registry and built-in tool implementations
- prompt assembly helpers
- settings and resource discovery
- skills
- slash commands
- hooks (before/after tool calls, file-op tracking, render hooks)
- optional custom tools
- event-bus pub/sub for extensions
- provider/model/API registry and provider loops (Anthropic streaming,
  OpenAI-compatible/OpenRouter, Ollama)
- v3 session JSONL formatting and loading
- line-oriented rendering for all modes (including markdown)
- cooperative scheduling of agent turns as coroutines
- future summary prompt customization

The host embeds Lua and exposes the runtime through a `psi.*` module surface
assembled in `lua/boot.lua`. See §10 for the current module list.

User code stays close to stock Lua 5.4 semantics, with host-specific
functionality confined to the `psi.*` modules.

#### Concurrency model: single thread, Lua coroutines

`lua_State` is strictly single-threaded and that fact drives the
whole host design. Rather than fight it, psi commits to a single OS
thread per process and expresses "do work while the UI stays
responsive" through Lua coroutines on top of non-blocking C
primitives.

Two C helpers make this possible:

- `src/core/http_async.c` runs `curl_easy_perform` on an internal
  helper pthread, enqueues chunks into a mutex-protected buffer, and
  exposes `psi_http_stream_begin / _poll / _finish`. The helper
  thread never touches Lua — it only pushes raw bytes.
- `src/core/process.c` fork/execs the shell command and reads stdout
  non-blockingly, exposing the same begin / poll / finish triple for
  `psi_process_*`. The blocking `psi_process_run_shell` is now a
  thin wrapper that drives the async state machine in a tight loop.

`lua/psi/sched.lua` wraps every agent turn in a coroutine. Each
cooperative yield (`sched.http_poll`, `sched.proc_poll`,
`sched.sleep_ms`) hands a small request table back to the driver;
between resumes the driver calls `psi.host_tick`, which the TUI
uses to run one iteration of its own event loop (non-blocking
getch → input dispatch → redraw when dirty). Because all of this
happens on the single thread that owns `lua_State`, the main
redraw path is free to call Lua (markdown, status line, etc.)
without any race.

All the C-side duplicates that existed to work around the old
worker-thread model — `psi_tui_footer_lines` (C status formatting),
`psi_tui_draw_assistant_line` (C markdown parser), the event queue
/ mutex / condvar — have been deleted. The TUI redraws via
`psi.tui_layout.status_line` + `psi.tui_layout.footer_hint` +
`psi.tui_layout.input_layout` + `psi.markdown.render_line`, fed
through a small ANSI-escape FSM that maps `\e[Nm` codes to ncurses
attrs.

Non-TUI modes (print, REPL, `--agent`, `--eval`, `--compact`) use
the same coroutine driver but install no tick hook, so
`psi.host_tick` is a no-op for them; they run the turn to completion
with cooperative yields internally but no UI interleaving.

### 4.4 provider layer

The provider layer is Lua policy over narrow host HTTP primitives.

It should not know about TUI details, slash commands, or session files.
It should only know:

- how to stream or complete a turn
- which tool schema format is needed
- how usage and stop reasons are reported
- which API adapter and compatibility flags apply to a model/provider

### 4.5 frontend layer

Frontends render host events and send host commands.

The frontend should never mutate the session model directly.

## 5. core runtime object

The central host object in `psi` is `psi_runtime`.

It owns:

- current configuration
- current provider/model selection
- current session
- current embedded Lua VM
- mode-specific service handles

Conceptually this is the C host for a Lua-side `AgentSession`-like runtime.
The C object is deliberately smaller than pi's `AgentSession`; Lua modules
provide the session manager, provider registry, resources, settings, tools,
and orchestration.

Proposed shape:

```c
struct psi_runtime {
    struct psi_config config;
    struct psi_session session;
    struct psi_vm vm;
};
```

The runtime is long-lived and mode-agnostic. The policy surface lives under
`lua/psi/*.lua`.

## 6. message model

`psi` should keep an explicit message union instead of flattening everything
into provider-native chat messages.

Required message kinds:

- user
- assistant
- tool-call
- tool-result
- bash-execution
- custom
- branch-summary
- compaction-summary

The Lua session body is the source of truth. The C message array is a compact
runtime cache exposed to modes and the embedded VM. Provider requests are
projections.

This is important because:

- persistence should be stable across providers
- TUI and RPC need the same event source
- summaries and host artifacts must survive model changes

## 7. session model

Sessions use the same conceptual model as `pi` where practical:

- append-only event log on disk
- typed JSONL entries with `id` and `parentId`
- current active branch stored in the in-memory order
- fork/clone support over the current active branch

Current on-disk format:

- newline-delimited JSON
- first record is a session header
- later records are typed entries
- version 3, compatible with pi's `custom_message` rename

Session entry families:

- message entries
- configuration changes
- branch summary entries
- compaction entries
- labels and metadata
- extension/custom persistence entries and custom model-context messages

Interactive tree navigation (`/tree`) and active-leaf branch switching are
still future work. The schema is now shaped so those can be added without
changing provider replay again.

## 8. tools

`psi` ships the following default set, registered in `lua/psi/tools.lua`:

- `read`
- `write`
- `edit`
- `bash`
- `grep`
- `find`
- `ls`
- `lua`

Tool design rules:

- host executes tools through a small C process layer (`src/core/process.c`)
  and host-ops surface (`src/core/host_ops.c`)
- provider sees tool schema, not host internals
- Lua owns the registry and can register new tools; dispatch still crosses an
  explicit host callback boundary
- tool results are persisted as first-class messages
- mutation tools serialize by path so concurrent tool calls cannot race on the
  same file
- tool specs carry execution metadata that frontends/providers can inspect
- before/after hooks run through `psi.tool_registry` so session provenance
  and file-op tracking can observe every call

## 9. Lua integration model

Lua 5.4 is embedded, not treated as a sidecar process.

The host is responsible for:

- VM lifecycle
- loading the bootstrap file (`lua/boot.lua`)
- loading host modules under `psi.*`
- registering C functions and userdata for host ops, session access, and
  process execution
- translating host errors into Lua errors and back

Lua is responsible for:

- tool registry contents and default tool implementations
- declarative skill metadata
- prompt snippets
- policy and workflow helpers
- slash commands, hooks, and render helpers

Important constraint from Lua's embedding model:

- host calls into Lua must go through `lua_pcall` (or an equivalent protected
  call) so that a Lua error cannot long-jump past C frames that own resources;
  the host should treat Lua calls as bounded transactions

This means the host treats Lua calls as bounded transactions:

- call into Lua under a protected frame
- get a value or error back
- resume host control

## 10. Lua modules

Currently shipped modules (see `lua/psi/`):

### `psi.tools` and `psi.tool_registry`

`psi.tools` holds the built-in tool implementations (`read`, `write`,
`edit`, `bash`, `grep`, `find`, `ls`, `lua`) and exposes
`psi.tools.dispatch_alist` for C glue. `psi.tool_registry` owns
declarative registration, schema capture, dispatch, and before/after
hook plumbing; extensions register new tools through it.

### `psi.session`

Session record construction, on-disk JSONL format (pi-compatible v3
with parent pointers, cache markers, file-op provenance, custom entries,
and custom model-context messages), load/save, fork, and compaction plumbing.

### `psi.prompt`

System prompt assembly: tool metadata, cwd, date, and context discovered by
`psi.resources`.

### `psi.providers`, `psi.anthropic`, `psi.openai_compat`, `psi.openrouter`, `psi.ollama`

Provider/model/API routing and provider loops. `psi.providers` owns the
compact registry and routing metadata; `psi.anthropic` streams the Anthropic
Messages API; `psi.openai_compat` owns the shared OpenAI-compatible skeleton;
`psi.openrouter` and `psi.ollama` supply provider-specific URL/header/body and
parser details. All providers funnel deltas through the same observer
interface so modes and extensions see a single event stream.

### `psi.settings`, `psi.resources`

Layered JSON settings (`~/.config/psi/settings.json` and
`./.psi/settings.json`) plus global/project context-file discovery.

### `psi.agent`

Thin orchestration wrapper around the current provider — one entry
point for "run a turn", "run compaction", etc. Keeps the mode layer
provider-agnostic.

### `psi.context`

Running per-turn usage mirror. Uses `psi.providers` model metadata when
available, then writes back into C (`psi.set_usage`) so the TUI status line
can read input/output/cache/total/window without calling Lua.

### `psi.render`, `psi.diff`, `psi.ansi`, `psi.markdown`

Line-oriented render helpers used by every mode, including the TUI.
`psi.render` owns the assistant-text and tool-call/result hooks;
`psi.diff` produces unified-diff blocks; `psi.ansi` is the small
colour helper; `psi.markdown` is the pure-Lua streaming gsub
renderer that styles assistant output live and also exposes
`render_line(line, in_code_fence)` for the TUI to call per wrapped
line. The TUI reuses all of these via a small ANSI-escape parser
in `src/runtime/tui_mode.c` that converts `\e[Nm` to ncurses attrs.

### `psi.sched`

Coroutine driver used by every agent turn. `sched.run(fn)` runs
`fn` as a coroutine; each yield describes a wait (`http`, `proc`,
`sleep`, `tick`) and is resolved by the C side via the
`psi.http_stream_*` / `psi.process_*` FFIs. Between resumes,
`psi.host_tick` gives whichever host installed a tick hook (the
TUI today) a chance to run one iteration of its own event loop.
This is the bridge that makes the single-threaded architecture
described in §4.3 work.

### `psi.events`

Neutral pub/sub bus (subscribe / unsubscribe / emit) used by extensions
for effects that don't fit the render hook's string-concat contract.
Bridged from the render events in `boot.lua` so extensions don't need
to pick a side.

### `psi.commands`

Slash-command registration and dispatch (`/help`, `/session`, `/fork`,
`/compact`, `/new`, `/clear`, ...). Extensions register their own
commands through `psi.commands.register`.

### `psi.modes`

Implements the non-TUI mode entry points (print, eval, system-prompt,
agent, compact, REPL) so the C host stays a thin dispatcher.

### `psi.tui`

Mode-aware hint strings and small helpers used by the TUI's C drawer.
Legacy status-line code lives here but is no longer called by the
redraw path (see §4.3).

### `psi.records`, `psi.tool_shell`, `psi.prelude`

Structured tool spec / tool result / message record constructors;
POSIX shell quoting for the `bash` tool; the prelude (UUIDs, JSON
helpers, safe reads, UTF-16 surrogate sanitising) used by the boot
script and every other module.

The host should keep these modules intentionally narrow. Direct
unrestricted host surfaces are easy to add later and hard to remove
cleanly.

## 11. mode architecture

### 11.1 print mode

Single request, single result, exit.

This is the first implementation target because it exercises:

- CLI parsing
- runtime initialization
- Lua bootstrap loading
- provider-independent request flow

### 11.2 interactive mode

Interactive mode runs on top of `libedit` and reuses the streamed Anthropic
loop.

### 11.3 TUI mode

`--tui` drives the same runtime under a full-screen `ncursesw` view. The TUI
is single-threaded: the main thread owns ncurses, the single `lua_State`,
and all transcript state. When the user presses Enter, `psi_tui_submit`
calls `psi_tui_run_turn_sync` which invokes the agent turn directly on the
same thread. The Lua turn runs inside a `psi.sched` coroutine; every
cooperative yield calls `psi.host_tick`, which routes to `psi_tui_tick` —
a small function that drains any pending input non-blockingly, dispatches
Esc / scroll / editing keys, and repaints if the transcript is dirty. A
UTF-8 locale is set before `initscr()` so unicode glyphs render correctly.

Observer callbacks run inline from the coroutine on the same thread, so
they mutate `state->entries[]` directly — no queue, no mutex, no
background thread. `psi_tui_observer_text_delta` etc. just append to the
streaming entry and set `transcript_dirty`; the next tick repaints.

TUI-specific rendering calls straight into Lua from the draw path:

- `psi.tui_layout.status_line` / `psi.tui_layout.footer_hint` build the
  footer/status strings
- `psi.tui_layout.input_layout` chooses prompt prefixes and the nominal
  visible-row cap for the multiline editor
- `psi.tui.handle_key` maps normalized keys (`enter`, `shift-enter`,
  `alt-b`, `ctrl-d`, `text`, ...) to editor actions such as submit,
  insert newline, delete word, quit, or abort
- `psi.markdown.render_line` styles each wrapped assistant line
- a small C ANSI-escape FSM (`psi_tui_draw_ansi_line`) converts the
  resulting `\e[Nm` codes to ncurses attrs / color pairs

The important rule is that the UI consumes host events rather than
becoming the place where state lives. Per-entry text is C-owned (because
the entry array is a C structure), but everything about how it renders
is Lua.

### 11.4 RPC mode

RPC mode should be a JSONL protocol over stdin/stdout, reusing the same runtime
object and event stream as interactive mode.

## 12. compaction and branch summaries

These should be implemented as explicit session operations, not hidden prompt
rewrites.

That implies:

- summaries are persisted
- summaries are visible to frontends
- summaries can carry structured details
- future Lua hooks can customize prompts or details

The first slice can defer implementation, but the runtime should reserve
message types for them now.

## 13. configuration and discovery

Configuration should be simple and layered:

- global config
- project config
- CLI overrides

Discovery surfaces:

- `AGENTS.md` / `CLAUDE.md`
- future `SKILL.md`
- local Lua modules under project config paths

As in `pi`, only summary metadata should be promoted into the always-on prompt.
Detailed skill content should be loaded on demand.

## 14. build and packaging

Build system choices:

- Nix flakes for reproducible builds and development
- Makefile for local direct builds
- no code generation required for the first milestone

The flake should:

- pull Lua 5.4 from nixpkgs
- expose a dev shell with compiler, make, pkg-config, libedit, libcurl,
  cJSON, and ncursesw
- build `psi`

The host should be compiled as C89 by default.

## 15. incremental implementation plan

### milestone 1

- flake
- Makefile
- core C89 project layout
- embedded Lua bootstrap
- `--eval`
- `--print`
- minimal session/message data structures

### milestone 2

- persistent session log
- basic `read`, `write`, `edit`, `bash`
- first Anthropic-backed model-facing turn loop
- provider abstraction

### milestone 3

- interactive mode with libedit
- command parsing
- project context loading
- simple skill loading
- ncurses-based `--tui` over the same runtime

### milestone 4

- tree navigation
- compaction
- branch summaries
- RPC mode

## 16. first implementation slice

The first code in this repository should prove four things:

- C89 host code builds cleanly
- Nix can reproduce the toolchain and embedded Lua dependency
- the host can register C functions in Lua
- Lua bootstrap code can be called from C as part of a runtime flow

That is enough to start building the real harness without committing to the
wrong boundaries.
