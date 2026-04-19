# psi port status

This file compares the current `psi` implementation with the `pi-mono`
architecture it is porting.

## Current mapping

| `pi-mono` concept | `pi-mono` reference | `psi` status |
| --- | --- | --- |
| Central session/runtime object | `packages/coding-agent/src/core/agent-session.ts` | Partial. `psi` still splits state between `psi_session`, tool dispatch, and the VM; a unified runtime object is not built yet. |
| Structured message model | `packages/coding-agent/src/core/messages.ts` | Partial. `psi` has user, assistant, tool-call, tool-result, branch-summary, compaction-summary roles, but no richer payloads yet. |
| Default coding tools | `packages/coding-agent/src/core/tools/` | Partial. `read`, `write`, `edit`, and `bash` exist through JSON host ops. `grep`, `find`, and `ls` are not ported yet. |
| Session persistence | `packages/coding-agent/docs/session.md` | Partial. `psi` persists JSONL session files, but they are still flat rather than branch-aware. |
| Project context discovery | `packages/coding-agent/src/core/resource-loader.ts` | Ported for `AGENTS.md` / `CLAUDE.md` discovery from cwd to root. Skills, prompt templates, and theme loading are not ported yet. |
| System prompt assembly | `packages/coding-agent/src/core/system-prompt.ts` | Ported in minimal form. `psi` now emits a coding-agent system prompt using tool metadata, guidelines, cwd, date, and project context files. |
| Interactive shell | `packages/coding-agent/src/modes/interactive/` | Early. `psi` has a simple Scheme REPL now backed by `libedit`, not the coding-agent event loop or TUI. |
| RPC mode | `packages/coding-agent/src/modes/rpc/` | Not started. |
| Compaction and summaries | `packages/coding-agent/src/core/compaction/` | Reserved in the message model only. |
| Skills and extensions | `packages/coding-agent/src/core/skills.ts`, `src/core/extensions/` | Not started beyond embedded Scheme bootstrap. |
| Provider/model loop | `packages/ai/`, `packages/coding-agent/src/modes/print-mode.ts` | Partial. `psi` now has a streamed Anthropic Messages API loop for single-shot `--agent` runs, with host tool execution and session logging. It is not yet an abstract multi-provider runtime. |

## Dependency audit

- `chibi-scheme`: keep. Small, embeddable, and aligned with the extension model.
- `cJSON`: acceptable. Small enough for the current JSONL and tool payload needs.
- `libedit`: replaces GNU Readline. This keeps the interactive dependency BSD-style instead of GPL.
- `ncurses`: not used yet; keep isolated until a real TUI exists.

## Next porting priority

The next structural gap is no longer the first provider loop. It is the runtime
shape around it:

1. introduce a real `psi_runtime` object that owns session, VM, tool registry,
   and provider configuration
2. split Anthropic-specific code behind a provider interface
3. enrich session persistence so assistant/tool blocks can be reconstructed
   without lossy role flattening
4. then layer interactive mode and RPC mode on top of that runtime

`psi` can now produce the coding-agent prompt, stream model output, and execute
host tools, but it is still not feature-complete relative to `pi-mono`.
