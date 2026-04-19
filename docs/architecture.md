# psi architecture

## 1. goals

`psi` should preserve the useful parts of `pi`'s harness model while removing
the TypeScript-first assumptions from the implementation.

Primary goals:

- keep the harness minimal and inspectable
- make the host runtime portable C89
- make Scheme the first extension surface
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
- RPC mode

Each mode is only an I/O shell around the same session object.

### 4.3 Scheme VM layer

Chibi-Scheme is embedded as the extension runtime.

Scheme is used for:

- skills
- prompt assembly helpers
- slash commands
- hooks
- optional custom tools
- future summary prompt customization

The host embeds Chibi and exposes explicit libraries such as:

- `(psi core)`
- `(psi session)`
- `(psi tools)`
- `(psi ui)`
- `(psi fs)`

The portable language contract presented to user code should remain close to
`R7RS-small`, with host-specific functionality in `psi` libraries.

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
- current embedded Scheme VM
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

`psi` should start with the same minimal default set:

- `read`
- `bash`
- `edit`
- `write`

Optional read-only helpers can come next:

- `grep`
- `find`
- `ls`

Tool design rules:

- host executes tools
- provider sees tool schema, not host internals
- Scheme can register new tools, but tool execution still happens through an
  explicit host callback boundary
- tool results are persisted as first-class messages

## 9. Scheme integration model

Chibi-Scheme is embedded, not treated as a sidecar process.

The host is responsible for:

- VM lifecycle
- loading the bootstrap file
- loading host libraries
- registering foreign procedures
- translating host errors into Scheme errors and back

Scheme is responsible for:

- declarative skill metadata
- prompt snippets
- policy and workflow helpers
- future commands and hooks

Important constraint from Chibi's embedding model:

- continuations should not be allowed to cross arbitrary host call boundaries
  in ways that make C control flow ambiguous

This means the host should treat Scheme calls as bounded transactions:

- call into Scheme
- get a value or exception back
- resume host control

## 10. Scheme libraries

Planned libraries:

### `(psi core)`

Small host facts and utility procedures:

- `(psi-version)`
- `(psi-log message)`
- `(psi-feature? symbol)`

### `(psi session)`

Session accessors and mutation helpers:

- current session id
- session cwd
- append custom messages
- future tree navigation hooks

### `(psi tools)`

Tool registration and tool-call helpers:

- define tool
- tool metadata helpers
- future argument validation hooks

### `(psi ui)`

Frontend-neutral user interaction hooks:

- notify
- confirm
- prompt
- future selector support

### `(psi fs)`

Small host filesystem helpers when direct Scheme-side file work is appropriate.

The host should keep this library intentionally narrow. Direct unrestricted host
surfaces are easy to add later and hard to remove cleanly.

## 11. mode architecture

### 11.1 print mode

Single request, single result, exit.

This is the first implementation target because it exercises:

- CLI parsing
- runtime initialization
- Scheme bootstrap loading
- provider-independent request flow

### 11.2 interactive mode

Interactive mode should come after the core session and tool loop exist.

Initial interactive mode can use `readline`.
Richer terminal rendering can later add `ncurses` where it is actually useful.

The important rule is that the UI must consume host events rather than becoming
the place where state lives.

### 11.3 RPC mode

RPC mode should be a JSONL protocol over stdin/stdout, reusing the same runtime
object and event stream as interactive mode.

## 12. compaction and branch summaries

These should be implemented as explicit session operations, not hidden prompt
rewrites.

That implies:

- summaries are persisted
- summaries are visible to frontends
- summaries can carry structured details
- future Scheme hooks can customize prompts or details

The first slice can defer implementation, but the runtime should reserve
message types for them now.

## 13. configuration and discovery

Configuration should be simple and layered:

- global config
- project config
- CLI overrides

Discovery surfaces:

- `AGENTS.md`
- future `SKILL.md`
- local Scheme libraries under project config paths

As in `pi`, only summary metadata should be promoted into the always-on prompt.
Detailed skill content should be loaded on demand.

## 14. build and packaging

Build system choices:

- Nix flakes for reproducible builds and development
- Makefile for local direct builds
- no code generation required for the first milestone

The flake should:

- build Chibi-Scheme from source
- expose a dev shell with compiler, make, pkg-config, readline, ncurses
- build `psi`

The host should be compiled as C89 by default.

## 15. incremental implementation plan

### milestone 1

- flake
- Makefile
- core C89 project layout
- embedded Chibi bootstrap
- `--eval`
- `--print`
- minimal session/message data structures

### milestone 2

- persistent session log
- basic `read`, `write`, `edit`, `bash`
- provider abstraction
- model-facing turn loop

### milestone 3

- interactive mode with readline
- command parsing
- project context loading
- simple skill loading

### milestone 4

- tree navigation
- compaction
- branch summaries
- RPC mode

## 16. first implementation slice

The first code in this repository should prove four things:

- C89 host code builds cleanly
- Nix can reproduce the toolchain and embedded Scheme dependency
- the host can register foreign procedures in Chibi
- Scheme bootstrap code can be called from C as part of a runtime flow

That is enough to start building the real harness without committing to the
wrong boundaries.

