# psi coding agent

`psi` is a rewrite of `pi` in C with Lua as its extension language.

The immediate goal is not feature parity with `pi-mono`. The goal is to keep
the same minimal harness philosophy while rebuilding the core around a simpler
runtime:

- C89 host runtime
- Lua 5.4 as the embedded extension language
- Nix flake based development and packaging
- A small, explicit core that grows from a working vertical slice

## Current status

This repository currently contains:

- an architecture document in [docs/architecture.md](docs/architecture.md)
- a port audit in [docs/port-status.md](docs/port-status.md)
- an extension authoring guide in [docs/extensions.md](docs/extensions.md)
- a provider catalogue in [docs/providers.md](docs/providers.md)
- a Nix flake that builds `psi` and its dependencies, plus cross-
  compile targets (`packages.psi-i686`, `packages.psi-static`,
  `packages.psi-static-i686` for musl ILP32/LP64 static binaries)
- `cJSON` for JSON session records and structured tool payloads
- `libcurl` for HTTPS provider integration
- `libedit` for interactive line editing without the GPL constraint of GNU Readline
- `ncursesw` (with UTF-8 locale) for the full-screen TUI
- `zlib` to gzip-compress embedded Lua sources and docs inside the binary
- an embedded Lua 5.4 runtime with host glue in `src/lua/vm.c` and a
  compressed embed-table (`include/psi/embedded_lua.h`) so portable
  static binaries carry their own Lua bootstrap and documentation
- a Lua bootstrap layer under `lua/` that owns the tool registry,
  prompt assembly, session records, render/markdown/diff helpers,
  provider loops, slash commands, and an extension loader
- a default coding-agent system prompt assembled from tools, cwd,
  date, and local `AGENTS.md` / `CLAUDE.md`
- a streamed Anthropic-backed `--agent` mode with host tool
  execution, prompt caching, dynamic token-accounting, and session
  logging in a pi-compatible v2 JSONL format
- an Ollama provider for local-first iteration (see
  [docs/providers.md](docs/providers.md))
- a default interactive coding-agent shell backed by the same
  streamed agent loop, with slash commands (`/help`, `/session`,
  `/fork`, `/compact`, `/new`, `/clear`, `/reload`,
  `/system-prompt`, `/quit`, tier-1/2/3 additions)
- a full-screen `--tui` mode with rich status (cwd / model /
  session / token usage), unicode tool-call borders, live
  markdown rendering, mode-aware hints, readline-style editing
  (Alt-B/F/D/Backspace, Ctrl-W/K/U), Esc-abort while busy, and
  Ctrl-Z suspend/resume. Single-threaded: the agent turn runs as
  a Lua coroutine on the ncurses thread, pumping input and
  redraws between every cooperative yield
- manual session compaction through `--compact` and `/compact`
- cooperative abort plumbing (Ctrl-C for non-TUI, Esc in TUI)
  that cancels the current curl transfer, kills any child
  process, and persists a truncated tool result
- static analysis wired into the flake (`nix run .#analyze`) with
  cppcheck + `gcc -fanalyzer`

It still does not contain the full `pi` session tree model, RPC
protocol, or a rich skills/extensions ecosystem. Those are described
in the architecture document and will be built incrementally.

## Quick start

Build with Nix:

```bash
nix build
./result/bin/psi --help
./result/bin/psi --eval '1 + 2 + 3'
./result/bin/psi --eval 'psi.tool_call("read", {path = "README.md"})'
./result/bin/psi --eval 'psi.tool_call("lua", {mode = "summary"})'
./result/bin/psi --system-prompt
ANTHROPIC_API_KEY=... ./result/bin/psi --agent 'Read README.md and summarize this repository.'
ANTHROPIC_API_KEY=... ./result/bin/psi --session /tmp/psi-session.jsonl
ANTHROPIC_API_KEY=... ./result/bin/psi --tui --session /tmp/psi-session.jsonl
ANTHROPIC_API_KEY=... ./result/bin/psi --session /tmp/psi-session.jsonl --compact 12
./result/bin/psi --print 'hello'
./result/bin/psi --session /tmp/psi-session.jsonl --print 'hello again'
```

For local development:

```bash
nix develop
make
./build/psi --eval '1 + 2 + 3'
./build/psi --eval 'psi.tool_call("read", {path = "README.md"})'
./build/psi --eval 'psi.tool_call("bash", {command = "true"})'
./build/psi --eval 'psi.tool_call("lua", {mode = "eval", expression = "#psi.tools.specs()"})'
./build/psi --system-prompt
set -a && . ./.env.local && ./build/psi --agent 'Say exactly: psi streaming test'
set -a && . ./.env.local && ./build/psi --session .psi/session.jsonl
set -a && . ./.env.local && ./build/psi --tui --session .psi/session.jsonl
set -a && . ./.env.local && ./build/psi --session .psi/session.jsonl --compact 12
./build/psi --print 'hello'
./build/psi --session .psi/session.jsonl --print 'hello again'
```

Session files are explicit for now. When `--session FILE` is set, `psi` loads
the JSONL file if it exists and rewrites it after each run. The on-disk
format matches `pi`'s v2 schema (headers, typed entries, parent pointers,
cache markers, file-op provenance); auto-save to a default path and
session-picker UI are planned (see the comparison in
[docs/port-status.md](docs/port-status.md)).

Current structured host tools registered in `lua/psi/tools.lua`:

- `read`
- `write`
- `edit`
- `bash`
- `grep`
- `find`
- `ls`
- `lua`

Tool inputs are plain Lua tables (or Lua alists when routed through the C
glue). The bootstrap and extensions live in Lua and dispatch through
`psi.tools.dispatch_alist` rather than a stringly JSON API.

`bash`, `grep`, `find`, and `ls` run through a small host process layer in
`src/core/process.c` that captures output and exit status using `fork`/`exec`
on POSIX.

`--system-prompt` is the current bridge from scaffold to usable harness
behavior. It emits the default coding-agent prompt that `psi` would hand to a
model, including discovered `AGENTS.md` / `CLAUDE.md` files from the current
working directory upward.

`--agent` is the first real coding-agent loop. It targets Anthropic's Messages
API, streams text to stdout as it arrives, executes built-in host tools, and
persists user/tool/assistant events in the session log. Starting `psi` with no
explicit mode opens the same agent loop in an interactive shell with `/help`,
`/session`, `/system-prompt`, `/compact`, and `/quit`. `--tui` opens a
full-screen ncurses view over the same runtime and uses the same Lua hook
renderers for tool execution blocks and diffs. The default model is
`claude-opus-4-7`, overridable via `--model` or `PSI_ANTHROPIC_MODEL`.

Session files are still flat JSONL, but assistant messages can persist an
extra structured payload so replay into Anthropic is less lossy than the
original plain-text-only form.

Current limitations of `--agent`:

- the TUI is smaller than `pi`'s; session tree navigation, clone,
  name, import/export, and a session picker are not yet built
- no RPC mode yet
- no streaming resume/retry logic
- session persistence is still a flat active-branch JSONL rather
  than a full branch tree walker
- compaction is summary-based and now dynamically token-aware, but
  not branch-aware
- two wired providers (Anthropic, Ollama); a general provider
  abstraction is not yet formalised

## Extensions

Lua files dropped into any of the following directories are
loaded at startup and can register tools, subscribe to events, or
add slash commands. See [docs/extensions.md](docs/extensions.md)
for the authoring guide.

- `$PSI_EXTENSIONS_DIR` (colon-separated list, takes precedence)
- `~/.config/psi/extensions/`
- `./.psi/extensions/`

## Layout

- `docs/architecture.md`: planned runtime architecture
- `docs/port-status.md`: audit against `pi-mono`
- `docs/extensions.md`: extension API surface and authoring guide
- `docs/providers.md`: provider catalogue and configuration
- `include/psi/`: public project headers (`abort`, `agent`,
  `anthropic`, `common`, `embedded_lua`, `host_ops`, `message`,
  `process`, `runtime`, `session`, `vm`)
- `src/main.c`: entry point and CLI dispatch
- `src/core/`: core host runtime (abort signal, agent loop,
  Anthropic client, host ops, process spawning, session I/O)
- `src/runtime/`: CLI parsing and the print/TUI runtime modes
  (including the TUI's C-side status + markdown drawers, which
  bypass Lua on the redraw path — see
  [docs/architecture.md §4.3](docs/architecture.md))
- `src/lua/vm.c`: Lua VM initialization, C-to-Lua glue, and the
  embedded-asset searcher / inflate plumbing
- `scripts/embed_lua.c`: build-time helper that deflate-compresses
  Lua sources and docs into C byte arrays
- `lua/boot.lua`: bootstrap that wires the `psi.*` Lua modules
  together, bridges render hooks onto the events bus, and loads
  extensions
- `lua/psi/`: Lua modules — tool registry, built-in tools, prompt
  assembly, session records/format, provider loops (Anthropic,
  Ollama), agent orchestration, slash commands, events bus,
  context mirror, render/diff/ANSI/markdown helpers, prelude
- `tests/`: smoke tests and valgrind harness
