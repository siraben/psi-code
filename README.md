# psi

A coding agent that builds with `cc *.c -o psi`.

---

`psi` is a terminal coding agent. The model in your terminal is the
same one in any other agent; what changes is what's underneath. Other
agents are 30 MB of TypeScript on top of Node, or a Go binary that
spawns Python subagents, or a Rust crate stack that takes ten minutes
to compile and weighs more than the operating systems it targets.
psi is a C89 host with a Lua 5.5 brain, written so the whole thing
compiles on machines that no longer get release notes.

It runs on Linux. It also runs on Haiku and 9front, and there are
ports to AmigaOS and ReactOS in flight. Not as a stunt — as the
single test that catches every assumption an agent might quietly make
about its host.

## Why

A coding agent is mostly text I/O around an HTTPS POST. The frontier
ships of this category have decided it's also: an Electron-class
runtime, a package manager, a plugin marketplace, a sandboxed
permissions UI, a sub-agent supervisor, a planner, a todo tracker, a
file-watching hot-reloader, and an MCP server. Each addition argues
for itself. Together they argue against being able to build the thing
from source.

psi takes the opposite bet. The agent loop, prompts, session schema,
TUI, providers, and tools are ~17k lines of pure Lua. The host —
process spawning, HTTP, terminal raw mode, Lua VM glue — is ~5k
lines of strict C89. Both halves fit in your head. There are no
build artifacts you didn't compile yourself.

## What's different

**One language for the brain, one for the body.** Lua 5.5 owns the
agent runtime: turn loop, providers, session JSONL, prompt assembly,
markdown rendering, slash commands, the TUI. C exists only at the OS
boundary. The split is enforced by the architecture, not just by
discipline — `lua_State` has exactly one owner thread, and helper
threads (libcurl, child processes) communicate through pollable
handles, never through Lua. See [docs/architecture.md](docs/architecture.md).

**Static binary, no runtime dependencies.** The Lua source and the
docs are deflate-compressed into the binary at build time. A
`packages.psi-static` musl build is a single self-contained file that
runs without Lua, without Node, without an interpreter on `$PATH`.
There's an i686 variant for the same reason there's a 9front port:
because nothing in the design ought to require a 64-bit POSIX 2017
host, and that's worth proving.

**Pi's philosophy, less the JavaScript.** psi is a port of [Mario
Zechner's pi-mono](https://github.com/badlogic/pi-mono) coding agent.
Its philosophy is also pi's: aggressively extensible, no plan mode,
no built-in todos, no permission popups, no MCP, no sub-agents, no
background bash. Build what you need as a Lua extension, or don't
build it. What's added on top is portability and a smaller surface:
extensions are single-file Lua drops, not npm packages.

**Portability as an honest test.** S9fES (Nils Holm's *Scheme 9 from
Empty Space*) is the model: build cleanly anywhere a C compiler
exists, replace one shim per platform, leave the rest untouched.
psi has more dependencies than S9fES does, but the shape is the
same — `src/core/process.c`, `src/core/http_async.c`,
`src/core/http_buffered.c`, and `src/runtime/tui_mode.c` are the
shims, the upstream `lua/psi/*.lua` brain is OS-agnostic. New port,
new platform directory, no edits upstream. See
[docs/portability.md](docs/portability.md).

**Extensions you can read in five minutes.** A psi extension is a
single `.lua` file dropped in `~/.config/psi/extensions/`. It
receives the `psi` global, registers tools or events or slash
commands, and that's it. There is no manifest, no version pinning, no
sandbox. If the file is hostile, you have bigger problems than your
agent. See [docs/extensions.md](docs/extensions.md).

## What it isn't

- A pi-mono replacement. Several pi features (session tree
  navigation, RPC mode, branch-aware compaction, the broad
  pi-managed model catalog) are tracked in [docs/port-status.md](docs/port-status.md)
  but not yet here.
- A platform. There is no plugin marketplace, no auto-update, no
  telemetry, no hosted backend. psi is a binary you build.
- An MCP host. Build a CLI and tell the model how to use it, or
  write an extension. The case against MCP is in [pi-mono's
  philosophy section](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent#philosophy);
  psi inherits the position.
- A sandbox. Tools run with the privileges of the user. Run psi in a
  container if that matters.

## Quick start

```bash
nix build
./result/bin/psi --help
ANTHROPIC_API_KEY=... ./result/bin/psi
```

That opens the full-screen TUI. The other entry points are flags on
the same binary:

```bash
psi --eval '1 + 2 + 3'                          # eval Lua against the runtime
psi --eval 'psi.tool_call("read", {path = "README.md"})'
psi --print 'hello'                             # one-shot, no streaming
psi --agent 'Read README.md and summarize.'     # one streaming turn
psi --repl                                      # libedit shell
psi --system-prompt                             # dump the assembled system prompt
psi --session /tmp/s.jsonl --compact 12         # auto-summarize older context
psi --model openai-codex/gpt-5.5 --thinking xhigh --agent '...'
```

For local development:

```bash
nix develop
make
./build/psi --eval 'psi.tool_call("lua", {mode = "summary"})'
```

Optional Make flags (each defaults to `1`, set to `0` to disable):

| Flag             | Effect                                                     |
|------------------|------------------------------------------------------------|
| `TUI`            | Full-screen frontend and `psi.tui_*` host primitives       |
| `ANSI`           | ANSI SGR emission and parsing (TUI implies this)           |
| `COLOR`          | Color SGR emission (non-color styles still allowed)        |
| `REPL_EDITLINE`  | libedit-backed REPL with history; `fgets` fallback if off  |

`make check-build-configs` builds the full toggle matrix into
isolated `BUILD_DIR=build-*` trees — the regression check whenever
preprocessor guards or optional dependencies move.

## Providers

Four providers are wired today. Provider selection is by `--model
<prefix>/<name>`, by `PSI_PROVIDER`, by `defaults.provider` in
settings, or by the Anthropic fallback. Full reference in
[docs/providers.md](docs/providers.md), or query at runtime:

```
psi> /apropos provider:
psi> /describe provider:anthropic
```

## Built-in tools

`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `lua` are
registered out of the box; extensions add more with
`psi.tools.register`. For each tool's full description and input
schema, ask psi:

```
psi> /apropos tool:
psi> /describe tool:bash
```

`bash`, `grep`, `find`, and `ls` run through a small host process layer in
`src/core/process.c` that captures output and exit status using `fork`/`exec`
on POSIX and `CreateProcess` + anonymous pipes on Windows.

### Windows (mingw-w64 cross)

Cross-build a `psi.exe` and run it under wine for end-to-end testing:

```bash
nix build .#psi-mingw
WINEPREFIX=$HOME/.wine64-psi wine64 result/bin/psi.exe --version
ANTHROPIC_API_KEY=… WINEPREFIX=$HOME/.wine64-psi \
  wine64 result/bin/psi.exe --agent 'run cmd /c ver and report it'
```

The mingw build cuts the TUI and libedit (POSIX-only); HTTPS goes
through libcurl + OpenSSL with an embedded CA bundle. See
[docs/portability.md](docs/portability.md#building-for-windows-mingw-w64)
for the full story (what's stubbed, why OpenSSL over schannel, etc.).
A `nix develop .#mingw` shell is also available for iterating compile
errors interactively.

## Layout

```
src/main.c              entry + CLI dispatch
src/core/               abort signal, process spawn, HTTP, sessions, TLS
src/runtime/            CLI parser, print/repl/agent dispatcher, TUI mode
src/lua/vm.c            Lua VM and the C↔Lua bridge
include/psi/            public host headers
scripts/embed.c         build-time deflate of Lua sources + docs into C arrays

lua/boot.lua            Lua bootstrap; wires psi.* and loads extensions
lua/psi/                tool registry, prompt assembly, session, scheduler,
                        markdown, diff, ANSI, theme, slash commands, TUI runtime
lua/psi/tools/          built-in tools — see "Built-in tools" above
lua/psi/providers/      anthropic, ollama, openrouter, openai_codex,
                        openai_compat, oauth_openai_codex
lua/psi/extensions/     bundled extensions (vim_keybindings, osc52_clipboard, btw)

docs/architecture.md    runtime model, what belongs in C vs. Lua
docs/portability.md     porting principles and per-OS predictions
docs/port-status.md     audit against pi-mono
docs/extensions.md      extension API surface and event catalog
docs/providers.md       provider catalogue and configuration

haiku/  9front/  amigaos/  reactos/   per-platform port artifacts
tests/                                  Python harnesses (smoke, bench, valgrind)
```

## Sessions

Sessions are append-only JSONL in pi's v3 schema: typed entries,
parent pointers, cache markers, file-op provenance, custom entries.
A session started under one provider can be resumed under another;
provider-specific thinking and signature blocks may be downgraded
during replay. Without `--session FILE`, psi assigns a path under
`$XDG_STATE_HOME/psi/sessions` (or `~/.local/state/psi/sessions`).

## Extensions

Drop a Lua file in any of:

- `$PSI_EXTENSIONS_DIR` (colon-separated, takes precedence)
- `~/.config/psi/extensions/`
- `./.psi/extensions/`

It runs at boot with the `psi` global available. Register tools,
subscribe to events, add slash commands or themes. The full API
surface is documented in [docs/extensions.md](docs/extensions.md).
Extensions run as local Lua code with the same filesystem and process
access as psi itself; review third-party and project-local extensions
before starting psi, or pass `--no-extensions` in untrusted checkouts.

## Status

The harness works. There is one streamed Anthropic-backed agent loop
shared by `--agent`, `--repl`, and `--tui`, plus three more provider
loops behind the same contract. Tool execution, prompt caching,
cooperative abort, dynamic token-aware compaction, OAuth flows
(OpenAI Codex), and the pi v3 session format are all in place.

What's missing relative to pi-mono is tracked in
[docs/port-status.md](docs/port-status.md). The largest gaps are
session-tree navigation, branch-aware compaction, RPC mode, and a
frozen extension-level provider registration API.
