# psi port status

This file compares the current `psi` implementation with the `pi-mono`
architecture it is porting.

## Current mapping

| `pi-mono` concept | `pi-mono` reference | `psi` status |
| --- | --- | --- |
| Central session/runtime object | `packages/coding-agent/src/core/agent-session.ts` | Partial. `psi` has a small `psi_agent_runtime` that owns session state and drives `--agent`, the interactive shell, and the TUI, but it is still much smaller than `pi`'s `AgentSession`. |
| Structured message model | `packages/coding-agent/src/core/messages.ts` | Ported. user, assistant, tool-call, tool-result, branch-summary, compaction-summary; assistant messages persist their full content-block array (text + tool_use + thinking blocks with signatures). |
| Default coding tools | `packages/coding-agent/src/core/tools/` | Ported. `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `lua` registered in `lua/psi/tools.lua`, dispatched through host glue with before/after hooks. |
| Session persistence | `packages/coding-agent/docs/session.md` | Ported to pi-style v3 JSONL schema: typed entries, parent pointers, cache markers, file-op provenance, custom entries, custom model-context messages, UTF-16 surrogate sanitising. Still single active-branch rather than a full tree walker. |
| Project context discovery | `packages/coding-agent/src/core/resource-loader.ts` | Ported for global/project `AGENTS.md` / `CLAUDE.md` discovery. Prompt templates are ported; skills and theme loading are not ported yet. |
| System prompt assembly | `packages/coding-agent/src/core/system-prompt.ts` | Ported via `psi.prompt`. Assembled from tool metadata, guidelines, cwd, date, and project context files; prompt caching applied per `pi`. |
| Interactive shell | `packages/coding-agent/src/modes/interactive/` | Ported. `libedit`-backed coding-agent shell over the streamed loop, slash commands include `/help`, `/session`, `/fork`, `/compact`, `/new`, `/clear`, `/reload`, `/system-prompt`, `/quit`, tier-1/2/3 additions. |
| Full-screen TUI | `packages/tui/` | Ported core. `--tui` runs the streamed agent loop under `ncursesw` on a single thread — the agent turn is a Lua coroutine driven by `psi.sched`, yielding cooperatively on HTTP / process poll so the redraw loop keeps up. Rich status line (cwd / model / session / token usage), unicode tool-call borders, live markdown, readline editing (Alt-B/F/D/Backspace, Ctrl-W/K/U), Esc-abort, and Ctrl-Z suspend. Smaller than `pi`'s TUI: no session tree view, no modals, no theme switching. |
| RPC mode | `packages/coding-agent/src/modes/rpc/` | Not started. |
| Compaction and summaries | `packages/coding-agent/src/core/compaction/` | Ported. Manual and dynamic token-aware auto-compaction; file-op provenance from `psi.session` feeds the compaction prompt. Not yet branch-aware. |
| Hooks and extensions | `packages/coding-agent/src/core/skills.ts`, `src/core/extensions/` | Early-to-partial. `psi.tool_registry` exposes before/after tool-call hooks; `psi.events` is a neutral pub/sub bus; `psi.commands.register` opens slash commands to extensions; boot loads Lua files from `$PSI_EXTENSIONS_DIR`, `~/.config/psi/extensions/`, and `./.psi/extensions/`. No npm/git package manager, no TS transpile, no sandboxing. |
| Abort / cancel plumbing | `packages/coding-agent/src/core/abort-signal.ts` | Ported. `AbortSignal` threaded through turn, compact, curl, and shell execution; transcript state ("aborted" / "error") recorded on each content block so the next turn sees a clean slate. |
| Provider/model loop | `packages/ai/`, `packages/coding-agent/src/modes/print-mode.ts` | Partial-to-ported. Streamed Anthropic Messages API, local Ollama, and OpenRouter share Lua provider routing plus the OpenAI-compatible adapter where applicable. Extension-level provider registration and the broad pi model catalog are not ported. |
| Tool output truncation | `packages/coding-agent/src/core/tools/truncate.ts` | Ported. `lua/psi/truncate.lua` mirrors `truncateHead` / `truncateTail` / `truncateLine` (2000 lines / 50 KiB / 500 chars) with UTF-8-safe tail slicing and the `[Showing lines X-Y of Z. Full output: /tmp/...]` continuation hints. `bash` tail-truncates and spills the full payload to a temp file via `psi.file_append` + `psi.tempfile_path`; `grep` head-truncates and clips long match lines; `find` / `ls` head-truncate by bytes; `read` keeps its `offset`/`limit` paging. |
| Markdown rendering of assistant output | `packages/tui/src/...` | Ported. Single pure-Lua `psi.markdown` module serves every mode; the TUI runs each wrapped line through `psi.markdown.render_line` on the main thread and paints the resulting ANSI escapes via a small C SGR parser. The earlier C duplicate has been deleted (see architecture §4.3). |
| Concurrency model | event loop / worker threads in `packages/coding-agent/src/core/` | Ported as single-threaded + Lua coroutines. The agent turn runs inside a `psi.sched` coroutine on the one thread that owns `lua_State`; HTTP streaming (`src/core/http_async.c`) and shell execution (`src/core/process.c`) use begin/poll/finish triples so every blocking point yields cooperatively, giving the TUI main loop a chance to pump input and redraw. |

## Dependency audit

- `lua5.4`: embedded as the extension language. Small, embeddable, and
  aligned with the extension model.
- `cJSON`: acceptable. Small enough for the current JSONL and tool payload needs.
- `libedit`: replaces GNU Readline. Keeps the interactive dependency BSD-style
  instead of GPL.
- `libcurl`: pragmatic choice for HTTPS provider integration. Heavier than the
  rest, but the portability tradeoff is worth it here.
- `ncursesw`: used by `--tui`. A UTF-8 locale is set before `initscr()` so
  unicode glyphs render correctly rather than appearing as caret-notation
  escapes.
- `argtable3`: CLI option parsing.
- `pthread`: used only by the `src/core/http_async.c` helper thread
  that runs `curl_easy_perform` behind a chunk queue. The TUI no
  longer has a worker thread; the agent turn runs as a Lua
  coroutine on the same thread that owns `lua_State` and ncurses.
- process execution: the safer process layer uses POSIX `fork`/`exec` on Unix
  and falls back to `system()` elsewhere. That is practical, but not strict
  portable C89.

## Next porting priority

The biggest remaining user-visible gaps are around session management
and extension richness:

1. **Session tree navigation.** Walk the `parentSession` pointers
   in session headers; add `/tree` and branch-aware forks that
   persist sibling branches alongside the active leaf. `/clone`
   and `/fork` already ship — they write to flat files rather
   than a tree walker. `/resume` / `/import` load a single file.
2. **Branch-aware compaction.** Let compaction know about siblings
   instead of treating the transcript as linear.
3. **Extension provider registration.** The Lua provider registry exists,
   but public registration/unregistration contracts need to be frozen before
   extensions can add providers safely.
4. **RPC mode.** JSONL over stdin/stdout reusing the same runtime
   and observer.

`psi` can now produce the coding-agent prompt, stream model output
from three providers, execute host tools, run interactively, render a
TUI with live markdown and rich status, and auto-compact sessions,
but it is still not feature-complete relative to `pi-mono`.
