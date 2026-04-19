# psi port status

This file compares the current `psi` implementation with the `pi-mono`
architecture it is porting.

## Current mapping

| `pi-mono` concept | `pi-mono` reference | `psi` status |
| --- | --- | --- |
| Central session/runtime object | `packages/coding-agent/src/core/agent-session.ts` | Partial. `psi` now has a small `psi_agent_runtime` that owns session state and drives both `--agent` and the interactive shell, but it is still much smaller than `pi`'s `AgentSession`. |
| Structured message model | `packages/coding-agent/src/core/messages.ts` | Partial. `psi` has user, assistant, tool-call, tool-result, branch-summary, and compaction-summary roles, and assistant messages can now persist structured payload JSON for better replay. |
| Default coding tools | `packages/coding-agent/src/core/tools/` | Ported in minimal form. `read`, `write`, `edit`, `bash`, `grep`, `find`, and `ls` are exposed through structured JSON host ops. |
| Session persistence | `packages/coding-agent/docs/session.md` | Partial. `psi` persists JSONL session files, but they are still flat rather than branch-aware. |
| Project context discovery | `packages/coding-agent/src/core/resource-loader.ts` | Ported for `AGENTS.md` / `CLAUDE.md` discovery from cwd to root. Skills, prompt templates, and theme loading are not ported yet. |
| System prompt assembly | `packages/coding-agent/src/core/system-prompt.ts` | Ported in minimal form. `psi` now emits a coding-agent system prompt using tool metadata, guidelines, cwd, date, and project context files. |
| Interactive shell | `packages/coding-agent/src/modes/interactive/` | Partial. `psi` now has a `libedit`-backed coding-agent shell that reuses the streamed Anthropic loop and supports a small slash-command set, but not `pi`'s TUI/event model. |
| RPC mode | `packages/coding-agent/src/modes/rpc/` | Not started. |
| Compaction and summaries | `packages/coding-agent/src/core/compaction/` | Early. `psi` now supports manual summary-based compaction through Anthropic, but it is not yet token-aware or branch-aware like `pi`. |
| Skills and extensions | `packages/coding-agent/src/core/skills.ts`, `src/core/extensions/` | Not started beyond embedded Scheme bootstrap. |
| Provider/model loop | `packages/ai/`, `packages/coding-agent/src/modes/print-mode.ts` | Partial. `psi` now has a streamed Anthropic Messages API loop for single-shot and interactive runs, with host tool execution, manual compaction calls, and session logging. It is not yet an abstract multi-provider runtime. |

## Dependency audit

- `chibi-scheme`: keep. Small, embeddable, and aligned with the extension model.
- `cJSON`: acceptable. Small enough for the current JSONL and tool payload needs.
- `libedit`: replaces GNU Readline. This keeps the interactive dependency BSD-style instead of GPL.
- `libcurl`: pragmatic choice for HTTPS provider integration. Heavier than the rest, but the portability tradeoff is worth it here.
- `ncurses`: not used yet; keep isolated until a real TUI exists.
- process execution: the current safer process layer uses POSIX `fork`/`exec` on Unix and falls back to `system()` elsewhere. That is practical, but not strict portable C89.

## Next porting priority

The next structural gap is still the runtime shape around the first provider
loop:

1. grow `psi_agent_runtime` into a fuller session/runtime object that can also own the VM and future extension state
2. split Anthropic-specific code behind a provider interface
3. add token-aware and branch-aware compaction closer to `pi`
4. build tree navigation and richer session management
5. then layer RPC mode and, later, a fuller TUI on top of that runtime

`psi` can now produce the coding-agent prompt, stream model output, execute host
tools, run interactively, and compact sessions manually, but it is still not
feature-complete relative to `pi-mono`.
