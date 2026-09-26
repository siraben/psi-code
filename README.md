# psi: The Portable Coding Agent

Coding agents are often slow, bloated and inscrutable. Complex for complexity's
sake. Can you name all of Claude Code's features? How long does it take to
compile Codex from source? (Hint: [almost an hour](http://hydra.nixos.org/build/331503530)
on macOS and [over an hour](https://hydra.nixos.org/build/331503528) on Linux.)

Some coding agents purport to follow the Unix philosophy, but fall short of
being a serious, real-world replacement for most use cases. Instead, we took a
ground-up approach. What's the most portable language? C. What's the most
portable, high-level runtime that is implemented in C? Lua.

The result is a coding agent that has superpowers for free. A 6 MB binary via
the [Cosmopolitan C library](https://github.com/jart/cosmopolitan) that runs on
macOS, Linux and Windows without modification. A coding agent that runs on
Haiku, *BSD, or your iPhone via [iSH](https://ish.app/).

psi has no shortage of features, including:

- support for many LLM backends, including Codex OAuth, OpenRouter, Ollama
- integration with MCP servers
- full session tree, forking and queue management
- skills
- interactive (CLI, TUI) and non-interactive use
- extensions and a self-documenting Lua runtime that can be modified on the fly
- sessions

Features we *don't* implement:

- No sandboxing. If you want it sandboxed, run it in a container or a VM.
- No plugin marketplace, hosted backend, telemetry, or auto-update service.

## Running psi

```ShellSession
$ nix run github:siraben/psi
```

For local development:

```ShellSession
$ nix develop
$ make
$ ./build/psi --help
```

The same binary supports the TUI, REPL, one-shot print mode, Lua eval, session
compaction, and direct agent turns:

```ShellSession
$ ANTHROPIC_API_KEY=... ./build/psi
$ ./build/psi --repl
$ ./build/psi --print 'hello'
$ ./build/psi --agent 'Read README.md and summarize.'
$ ./build/psi --eval 'psi.tool_call("read", {path = "README.md"})'
$ ./build/psi --session /tmp/s.jsonl --compact 12
$ ./build/psi --model openai-codex/gpt-5.5 --thinking xhigh --agent '...'
```

## Design goals

psi aims to be:

- The most portable and extensible coding agent in the world.
- Fully auditable (via a Software Bill of Materials)
- Practical (we daily drive psi)
- Open source

## Design Philosophy

psi is heavily inspired by the [pi coding agent](https://github.com/earendil-works/pi).
Like pi, psi aims to implement only the base functionality in-tree, and then
defer features to Lua extensions written by the user, such as the TUI
rendering, queue management, even the agent loop itself.

The extension language is Lua because of the following reasons we've observed:

- LLMs can write good, idiomatic Lua
- Lua's runtime has minimal dependencies
- Lua is reasonably fast and can support modern programming styles and
  abstractions.

We chose C89 for the base implementation because of its extreme portability.
Most platforms, even non-POSIX ones, have a compiler for C89.

## Dependencies

Things that have to be fast (e.g. networking) are done in C89 with minimal
dependencies. We use:

- libedit
- ncurses
- curl with mbedTLS
- wcwidth-compatible Unicode cell-width handling
- zlib
- cJSON
- a C compiler
- a libc

Optional Make flags default to `1`; set them to `0` to disable the feature.

| Flag | Effect |
|---|---|
| `TUI` | Inline terminal frontend and `psi.tui_*` host primitives |
| `ANSI` | ANSI SGR emission and parsing. Required by `TUI`. |
| `COLOR` | Color SGR emission. Non-color styles can still be used. |
| `MCP` | Stdio process primitives for protocol clients. |
| `REPL_EDITLINE` | libedit-backed REPL with history. Falls back to `fgets`. |

Run the build-matrix check when optional dependencies or preprocessor guards
change:

```ShellSession
$ make check-build-configs
```

Dependency SBOM generation and vulnerability gating are available with:

```ShellSession
$ nix run .#audit-sbom
```

See [docs/dependency-audit.md](docs/dependency-audit.md).

## How portable is it?

We've tested on the following operating systems (on i686, x86_64, aarch64,
riscv64 where available):

Linux, macOS, Windows, Haiku, OpenBSD, FreeBSD.

Really, any operating system that supports a POSIX-like API surface can run psi.

Beyond just being able to *run* psi, we also support a wide variety of ways to
*compile* and *link* psi. For the clib layer, we've tested glibc, musl,
cosmopolitan, fil-c, c-ward. For the C compiler itself, we've tested gcc (4.6
through 15), clang, CompCert, TCC.

See [docs/portability.md](docs/portability.md).

## Providers

Provider selection works through `--model <prefix>/<name>`, `PSI_PROVIDER`,
`defaults.provider` in settings, or the Anthropic fallback. Built-in providers
include:

- Anthropic
- Ollama
- OpenRouter
- OpenAI Codex

Ask the running agent for live provider metadata:

```text
psi> /apropos provider:
psi> /describe provider:anthropic
```

See [docs/providers.md](docs/providers.md).

## Tools and extensions

`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, and `lua` are registered
out of the box. Extensions add more with `psi.tools.register`.

Drop a Lua file in any of:

- `$PSI_EXTENSIONS_DIR` (colon-separated, loaded first)
- `~/.config/psi/extensions/`
- `./.psi/extensions/`

It runs at boot with the `psi` global available. Register tools, subscribe to
events, add slash commands, customize themes, or hook the TUI. Extensions are
trusted local code with the same filesystem and process access as psi itself;
project-local extensions load only after the workspace is trusted. Interactive
sessions prompt once; non-interactive modes skip untrusted project resources.
Use `--trust` or `--no-trust` to override that decision for one run.

See [docs/extensions.md](docs/extensions.md).

An optional, disabled-by-default network-search reference tool is documented in
[docs/network-search.md](docs/network-search.md). It is implemented entirely as
a bundled Lua extension over psi's existing HTTP and credential primitives; it
does not add an MCP or core search dependency.

## Skills

Put each skill's `SKILL.md` under `~/.config/psi/skills/<name>/` or
`./.psi/skills/<name>/` (use `$XDG_CONFIG_HOME/psi/skills/` when set).
The file needs frontmatter with a single-line `description` and may set `name`.
Psi lists skill names, descriptions, and file paths in the system prompt;
the agent reads the full file with `read` when a task matches. Project skills
load only after the workspace is trusted. Set `disable-model-invocation: true`
to keep a skill out of the model's list. Skill packages, `/skill:name`, and
`.agents/skills` discovery are not implemented.

## Sessions

Sessions are append-only JSONL in pi's v3 schema: typed entries, parent
pointers, cache markers, file-op provenance, custom entries, custom
model-context messages, compaction summaries, and branch summaries.

A session started under one provider can be resumed under another.
Provider-specific thinking and signature blocks may be downgraded during replay.
Without `--session FILE`, psi assigns a path under
`$XDG_STATE_HOME/psi/sessions` or `~/.local/state/psi/sessions`.

Use `/tree` to show the session tree or `/tree <entry-id> --summarize` to switch
branches while preserving the branch you leave as summary context. `/branch`
and `/branches` remain text aliases for quick inspection and switching.

## Repository layout

```text
src/main.c              entry point and CLI dispatch
src/core/               abort signal, process spawn, HTTP, sessions, TLS
src/runtime/            CLI parser, print/repl/agent dispatch, TUI mode
src/lua/vm.c            Lua VM and C/Lua bridge
include/psi/            public host headers
scripts/embed.c         build-time deflate of Lua sources and docs

lua/boot.lua            Lua bootstrap; wires psi.* and loads extensions
lua/psi/                tools, prompts, sessions, scheduler, markdown, TUI
lua/psi/tools/          built-in tool implementations
lua/psi/providers/      Anthropic, Ollama, OpenRouter, OpenAI Codex adapters
lua/psi/extensions/     bundled extensions

docs/architecture.md    runtime model and host/runtime boundaries
docs/portability.md     porting principles and per-OS notes
docs/port-status.md     audit against pi-mono
docs/extensions.md      extension API and event catalog
docs/providers.md       provider configuration

tests/                  Python harnesses for smoke, bench, and valgrind runs
```

## Evals

There is no published eval suite yet. The repository uses smoke tests,
build-matrix checks, benchmark harnesses, and valgrind-oriented tests under
`tests/`.

## Naming

psi was supposed to be a fork of pi that used Scheme as the extension language
(hence p**s**i), but owing to the complexity of runtimes and in pursuit of a
more minimal, perfect coding agent, we ultimately chose Lua instead.

## License

The project is MIT licensed.
