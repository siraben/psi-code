# psi architecture

## 1. goals

`psi` should preserve the useful parts of `pi`'s harness model while removing
the TypeScript-first assumptions from the implementation.

Primary goals:

- keep the harness minimal and inspectable
- make the host runtime portable C89
- make Lua the first extension surface
- keep core state and persistence in C
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
- message model
- session model
- session persistence
- tool registration and execution
- provider abstraction
- runtime configuration

The host core is authoritative for state.

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
- skills
- slash commands
- hooks (before/after tool calls, file-op tracking, render hooks)
- optional custom tools
- event-bus pub/sub for extensions
- provider loops (Anthropic streaming, Ollama)
- line-oriented print/REPL rendering (including markdown)
- future summary prompt customization

The host embeds Lua and exposes the runtime through a `psi.*` module surface
assembled in `lua/boot.lua`. See §10 for the current module list.

User code stays close to stock Lua 5.4 semantics, with host-specific
functionality confined to the `psi.*` modules.

#### Thread-safety constraint (important)

Lua is strictly single-threaded: one `lua_State` cannot be touched by two
OS threads simultaneously. The TUI mode (§11.3) runs the agent turn on a
worker thread; that worker holds the VM for the entire turn. As a result,
**the main thread must not call Lua during a streaming turn** — it would
race the worker and has empirically produced SIGSEGVs deep in
`luaV_execute` / `luaL_error`.

This pushes a small amount of "render helper" code from Lua into C
specifically for the TUI main-thread redraw path:

- TUI status line formatting (cwd, session id, model, token usage)
- TUI inline markdown rendering (bold / italic / code / headings /
  fenced blocks) in the assistant-entry drawer
- TUI diff-style colouring for write/edit tool results

Non-TUI modes (print, REPL, --agent, --eval, --compact) never run Lua
concurrently with anything else and so continue to render through the
Lua `psi.render` / `psi.markdown` modules. The result is a deliberate
duplication: the `psi.markdown` Lua module and a small C parser in
`src/runtime/tui_mode.c` implement overlapping grammars for print and
TUI respectively. The cost of duplication is lower than the cost of
introducing a second `lua_State` for the main thread or serialising
every redraw against the worker.

### 4.4 provider layer

The provider layer is a narrow C interface around one or more model backends.

It should not know about TUI details, slash commands, or session files.
It should only know:

- how to stream or complete a turn
- which tool schema format is needed
- how usage and stop reasons are reported

### 4.5 frontend layer

Frontends render host events and send host commands.

The frontend should never mutate the session model directly.

## 5. core runtime object

The central object in `psi` is `psi_runtime`.

It owns:

- current configuration
- current provider/model selection
- current session
- current tool table
- current embedded Lua VM
- mode-specific service handles

Conceptually this is the C replacement for `AgentSession` plus the runtime host
used by `pi`.

Proposed shape:

```c
struct psi_runtime {
    struct psi_config config;
    struct psi_session session;
    struct psi_tool_registry tools;
    struct psi_vm vm;
};
```

The runtime is long-lived and mode-agnostic.

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

The host model is the source of truth. Provider requests are projections.

This is important because:

- persistence should be stable across providers
- TUI and RPC need the same event source
- summaries and host artifacts must survive model changes

## 7. session model

Sessions should use the same conceptual model as `pi`:

- append-only event log on disk
- tree structure via `id` and `parent_id`
- one active leaf pointer
- branch navigation inside a single session file

Recommended on-disk format:

- newline-delimited JSON
- first record is a session header
- later records are typed entries

Session entry families:

- message entries
- configuration changes
- branch summary entries
- compaction entries
- labels and metadata
- extension/custom persistence entries

The first milestone does not need the full file format, but the in-memory model
should be shaped for it immediately.

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

Session record construction, on-disk JSONL format (pi-compatible v2
with parent pointers, cache markers, file-op provenance), load/save
and fork/compaction plumbing.

### `psi.prompt`

System prompt assembly: tool metadata, cwd, date, and discovered
`AGENTS.md` / `CLAUDE.md` context.

### `psi.anthropic`, `psi.ollama`

Provider loops. `psi.anthropic` streams the Anthropic Messages API with
prompt caching, tool-use round-tripping, and per-turn usage accounting;
`psi.ollama` is a local-first provider for offline iteration. Both
funnel their deltas through the same observer interface so modes and
extensions see a single event stream.

### `psi.agent`

Thin orchestration wrapper around the current provider — one entry
point for "run a turn", "run compaction", etc. Keeps the mode layer
provider-agnostic.

### `psi.context`

Running per-turn usage mirror. Writes back into C (`psi.set_usage`) so
the TUI status line can read input/output/cache/total/window without
calling Lua.

### `psi.render`, `psi.diff`, `psi.ansi`, `psi.markdown`

Line-oriented render helpers for print / REPL / `--agent` modes.
`psi.render` owns the assistant-text and tool-call/result hooks;
`psi.diff` produces unified-diff blocks; `psi.ansi` is the small
colour helper; `psi.markdown` is the pure-Lua streaming gsub
renderer that styles assistant output live. The TUI does not use
these (see §4.3 thread-safety note) — it has its own C-side drawer.

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
runs the agent turn on a worker thread; tool calls, tool results, text deltas
and thinking deltas are pushed to a C-owned event queue and drained on the
main (redraw) thread between `getch()` ticks. A UTF-8 locale is set before
`initscr()` so unicode glyphs render correctly.

Because the worker holds the single `lua_State` for the duration of a turn
(§4.3), the main thread **does not call Lua during a streaming turn**. In
practice this means the TUI has its own small C-side renderers for
anything that needs to run during a redraw:

- `psi_tui_footer_lines` — status / usage line, reads the `psi_host_usage`
  mirror in C directly
- `psi_tui_draw_assistant_line` — inline markdown (bold, italic, code,
  headings, fenced blocks) in the assistant entry drawer
- `psi_tui_line_style` — diff-style coloring scoped to `write` / `edit`
  tool results and compaction summaries

The important rule is that the UI must consume host events rather than becoming
the place where state lives. Per-entry text is C-owned, so redraws are
deterministic even if Lua is mid-`lua_pcall` on the worker thread.

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
