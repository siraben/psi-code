# psi coding agent

`psi` is a rewrite of `pi` in C with Lua as its extension language.

The immediate goal is not feature parity with `pi-mono`. The goal is to keep
the same minimal harness philosophy while rebuilding the core around a simpler
runtime:

- C99 host runtime
- Lua 5.4 as the embedded extension language
- Nix flake based development and packaging
- A small, explicit core that grows from a working vertical slice

## Current status

This repository currently contains:

- an architecture document in [docs/architecture.md](docs/architecture.md)
- a port audit in [docs/port-status.md](docs/port-status.md)
- a Nix flake that builds `psi` and its dependencies
- `cJSON` for JSON session records and structured tool payloads
- `libcurl` for Anthropic Messages API integration
- `libedit` for interactive line editing without the GPL constraint of GNU Readline
- `ncursesw` (with UTF-8 locale) for the full-screen TUI
- an embedded Lua 5.4 runtime with host glue in `src/lua/vm.c`
- a Lua bootstrap layer under `lua/` that owns the tool registry, prompt
  assembly, session records, hook dispatch, and render helpers
- a default coding-agent system prompt assembled from tools, cwd, date, and local `AGENTS.md` / `CLAUDE.md`
- a streamed Anthropic-backed `--agent` mode with host tool execution and session logging
- a default interactive coding-agent shell backed by the same streamed agent loop
- a full-screen `--tui` mode backed by the same streamed agent loop and Lua hook renderers
- manual session compaction through `--compact` and `/compact`

It still does not contain the full `pi` session tree model, RPC protocol, or
skills/extensions layer. Those are described in the architecture document and
will be built incrementally.

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
the JSONL file if it exists and rewrites it after each run.

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

- the TUI is still much smaller than `pi`'s interactive mode
- no RPC mode yet
- no streaming resume/retry logic
- session persistence is still flat JSONL rather than a full branch tree
- compaction is manual and summary-based, not `pi`'s fuller token-aware system
- only Anthropic is wired today; there is no provider abstraction yet

## Layout

- `docs/architecture.md`: planned runtime architecture
- `docs/port-status.md`: audit against `pi-mono`
- `include/psi/`: public project headers (`agent`, `anthropic`, `common`,
  `host_ops`, `message`, `process`, `prompt`, `runtime`, `session`, `vm`, ...)
- `src/main.c`: entry point and CLI dispatch
- `src/core/`: core host runtime (agent loop, Anthropic client, host ops,
  messages, process spawning, prompt assembly, session I/O)
- `src/runtime/`: CLI parsing and the print/TUI runtime modes
- `src/lua/vm.c`: Lua VM initialization and C-to-Lua glue
- `lua/boot.lua`: bootstrap that wires the `psi.*` Lua modules together
- `lua/psi/`: Lua modules for the tool registry, built-in tools, prompt
  rendering, session records, hooks, diff, ANSI, and render helpers
- `tests/`: smoke tests
