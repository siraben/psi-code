# psi port status

This file tracks `psi` against the `pi-mono` architecture it ports.

## Current mapping

| `pi-mono` concept | `pi-mono` reference | `psi` status |
| --- | --- | --- |
| Central session/runtime object | `packages/coding-agent/src/core/agent-session.ts`, `agent-session-runtime.ts` | Ported in psi-native form. Lua `psi.agent_session` owns provider/model state and agent operations; the small `psi.agent_runtime` facade owns bootstrap/resume, observer composition, persistence, compaction, session replacement, and shutdown across print, agent, REPL, TUI, compact, and future RPC frontends. Mode-specific input and rendering remain outside the facade, and C remains the host boundary. |
| Structured message model | `packages/coding-agent/src/core/messages.ts` | Ported. User, assistant, tool-call, tool-result, branch-summary, and compaction-summary entries are supported. Assistant messages persist their full content-block array: text, tool_use, and thinking blocks with signatures. |
| Default coding tools | `packages/coding-agent/src/core/tools/` | Ported. `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `lua` registered in `lua/psi/tools.lua`, dispatched through host glue with before/after hooks. |
| Session persistence | `packages/coding-agent/docs/session-format.md` | Ported to pi-style v3 JSONL schema: typed entries, parent pointers, cache markers, file-op provenance, custom entries, custom model-context messages, branch summaries, UTF-16 surrogate sanitising, and branch-safe append-only compaction. Lua keeps the file's entry tree and can rebuild the active path from `parentId` links. Graphical tree UX (selectors) is not ported; durable tree tracking and text `/tree` navigation are in place. |
| Project context discovery | `packages/coding-agent/src/core/resource-loader.ts` | Ported for global/project `AGENTS.md` / `AGENTS.MD` / `CLAUDE.md` / `CLAUDE.MD` first-candidate discovery, `--no-context-files`, `.psi/SYSTEM.md`, `.psi/APPEND_SYSTEM.md`, prompt-template opt-out and explicit template loading. Global and trusted project skills advertise metadata from `SKILL.md`; `/skill:name`, `.agents/skills`, and package-supplied skills are not ported. |
| Project trust | `packages/coding-agent/src/core/project-trust.ts`, `trust-manager.ts` | Ported in Lua. Canonical-path decisions inherit from the nearest ancestor; interactive sessions prompt once; non-interactive sessions deny by default; and project settings, extensions, prompts, skills, keybindings, and system-prompt files stay gated. psi uses `--trust` / `--no-trust` and `PSI_TRUST` instead of pi's approval flags, and has no package or theme directories to gate. |
| System prompt assembly | `packages/coding-agent/src/core/system-prompt.ts` | Ported via `psi.prompt`. Assembled from tool metadata, guidelines, cwd, date, system/append files, XML-wrapped project context files, and discoverable skill metadata. A trusted `SYSTEM.md` replaces the built-in preamble, tool prose, rules, and docs. Structured prompt-section patches and durable system-message checkpoints are not ported. Prompt-cache controls remain provider-specific rather than a full pi cache-key implementation. |
| Interactive shell | `packages/coding-agent/src/modes/interactive/` | Ported. `libedit`-backed coding-agent shell over the streamed loop. The full slash-command set is documented in `docs/extensions.md`; canonical source is `BUILTIN_COMMANDS` in `lua/psi/slash_commands.lua`. |
| Inline TUI | `packages/tui/` | Ported core. `--tui` runs the streamed agent loop in raw terminal mode with Lua-owned ANSI rendering on one thread. It defaults to the normal terminal screen buffer instead of alt screen so terminal scrollback and tmux selection keep working. The agent turn is a `psi.sched` coroutine that yields on HTTP/process polls so redraws continue. The TUI has pi-style persistent component primitives (`Container`, `Block`, `Spacer`, `Text`, `Box`, `Border`), generation-based render caches, componentized markdown/table rendering, tool execution boxes, dynamic child mounting, focus routing, anchored overlays, and line-frame differential rendering. It also has a two-row path/modeline footer with usage and context coloring, footer-line extension hooks, a searchable Ctrl-L model picker, a Ctrl-T thinking-visibility toggle, pending queue rendering, queue subcommands, unicode tool-call borders, live markdown, readline editing, hardware-cursor prompt editing, optional Vim mode, Escape abort with queue restore, Ctrl-G external editor, Ctrl-Z suspend, text `/tree` navigation, and a Lua theme registry. Still missing: graphical session tree selector, reusable selector components, and an interactive theme picker. |
| RPC mode | `packages/coding-agent/src/modes/rpc/` | Not started. |
| Compaction and summaries | `packages/coding-agent/src/core/compaction/` | Ported. Manual and configurable token-aware auto-compaction runs before prompts and after complete turns across every provider, with one compact-and-retry attempt for provider context overflows. Cut points are selected before summary generation, split turns receive a separate prefix summary, structured tool/thinking content is serialized, and file-op provenance accumulates in model-visible summaries. Compaction appends a compacted active branch without dropping sibling branches. `/tree <id> --summarize` can summarize the abandoned branch and attach a `branch_summary` entry at the destination. Extensions can cancel compaction or supply a summary before provider work; pi's full compaction extension contract is not ported. |
| Hooks and extensions | `packages/coding-agent/src/core/extensions/` | Partial. `psi.tool_registry` exposes before/after tool-call hooks; `psi.events` supports exact unsubscription and cancellable/custom compaction summaries; `psi.commands.register` opens slash commands to extensions; boot loads Lua files from `$PSI_EXTENSIONS_DIR`, `~/.config/psi/extensions/`, and `./.psi/extensions/`. Extension providers, tool renderers, the broader pi event catalog, and scoped extension lifecycles are not ported. There is no npm/git package manager, TypeScript transpile step, or sandbox. |
| Abort / cancel plumbing | `packages/coding-agent/src/core/abort-signal.ts` | Ported. `AbortSignal` threaded through turn, compact, curl, and shell execution; transcript state ("aborted" / "error") recorded on each content block so the next turn sees a clean slate. |
| Provider/model loop | `packages/ai/`, `packages/coding-agent/src/modes/print-mode.ts` | Partial-to-ported. Anthropic Messages, local Ollama, OpenRouter, OpenAI Codex (Responses plus ChatGPT OAuth), and Moonshot share Lua provider routing and compatible adapters where applicable. Extension-level provider registration and the broad pi model catalog are not ported. |
| Tool output truncation | `packages/coding-agent/src/core/tools/truncate.ts` | Ported. `lua/psi/truncate.lua` mirrors `truncateHead` / `truncateTail` / `truncateLine` (2000 lines / 50 KiB / 500 chars) with UTF-8-safe tail slicing and the `[Showing lines X-Y of Z. Full output: /tmp/...]` continuation hints. `bash` tail-truncates and spills the full payload to a temp file via `psi.file_append` + `psi.tempfile_path`; `grep` head-truncates and clips long match lines; `find` / `ls` head-truncate by bytes; `read` keeps its `offset`/`limit` paging. |
| Markdown rendering of assistant output | `packages/tui/src/...` | Ported. Assistant output now flows through a Lua component path: markdown inline tokens are parsed before styling, paragraph blocks are wrapped after styling with ANSI-aware display width, and tables render as reusable TUI component output. C owns the shared terminal text primitives (ANSI/OSC stripping, UTF-8 cell width, clipping, padding, wrapping) and the terminal boundary receives logical line frames for differential row rendering when `--tui` is active. |
| Concurrency model | event loop / worker threads in `packages/coding-agent/src/core/` | Ported as single-threaded + Lua coroutines. The agent turn runs inside a `psi.sched` coroutine on the one thread that owns `lua_State`; HTTP streaming (`src/core/http_async.c`) and shell execution (`src/core/process.c`) use begin/poll/finish triples so every blocking point yields cooperatively, giving the TUI main loop a chance to pump input and redraw. |

## Audit snapshot: 2026-09-24

Compared against `badlogic/pi-mono` at `5fd446ca` after fast-forwarding its
local checkout. The changes on `siraben/pi-mono-parity-sep-2026` address these
concrete differences while keeping policy in Lua and the C89 host unchanged:

| Surface | Brought closer to pi | Remaining gap |
| --- | --- | --- |
| UI | ANSI column slicing preserves and closes OSC 8 links, including styled links clipped beside overlays. Idle inline/chat views, the resume picker, and the new searchable model picker repaint when terminal dimensions change. The two-row footer now uses a dim path/modeline, compact cumulative token/cache stats, a context meter with warning/error colors, and the current model/thinking level; extensions can add footer rows. Ctrl-T toggles thinking blocks between full text and a placeholder without dropping their content. | The model picker is a small text-row picker rather than pi's reusable fuzzy selector. Graphical session/tree selectors, an interactive theme picker, chat scrollback reflow of committed lines after resize, editor undo/kill-ring parity, and advanced keyboard-protocol negotiation remain absent. Psi's thinking toggle lasts for the current session rather than persisting in settings. |
| Extensions | Wrapped path completion; event unsubscribe closures; `session_before_compact` can cancel or supply a summary before provider work, with an abort check before rewriting. | Provider registration, scoped lifecycles, tool renderers, and much of pi's event catalog need a Lua API design. |
| Prompts and skills | Trusted `SYSTEM.md` replaces built-in prompt sections; skill names, descriptions, and read paths are advertised without loading full instructions into the prompt. | Structured system-message sections and prompt patches, `/skill:name`, `.agents/skills`, and package resources remain unported. |
| Tools | `find` supports path globs and nested Git ignores outside repositories; `grep` limits matches rather than context rows and treats no matches as a successful search. | psi expects `fd` and `rg` on the host; pi's runtime downloader is deliberately omitted. |
| Sessions | Loading an unterminated valid or malformed JSONL tail repairs its line boundary before append. | Canonical context edits and durable prompt/tool checkpoints from current pi need a larger session-model migration. |

Node/TypeScript package loading, transpilation, runtime downloads, and native
theme/color machinery remain outside psi's small C/Lua runtime model.

## Dependency audit

- `lua5.5`: embedded as the extension language. Small, embeddable, and aligned
  with the extension model.
- `cJSON`: acceptable for current JSONL and tool payload needs.
- `libedit`: replaces GNU Readline. Keeps the interactive dependency BSD-style
  instead of GPL.
- `libcurl`: pragmatic choice for HTTPS provider integration. It is heavier than
  the rest, but replacing TLS and provider streaming would cost more.
- ANSI terminal control: used by `--tui` for inline rendering. A UTF-8
  locale is set before entering raw mode so unicode glyphs render correctly.
  The Lua TUI has no non-ANSI renderer, so `ANSI=0` disables TUI support at
  compile time.
- `argtable3`: CLI option parsing.
- `pthread`: used only by the `src/core/http_async.c` helper thread
  that runs `curl_easy_perform` behind a chunk queue. The TUI no
  longer has a worker thread; the agent turn runs as a Lua
  coroutine on the same thread that owns `lua_State` and terminal rendering.
- process execution: the safer process layer uses POSIX `fork`/`exec` on Unix
  and falls back to `system()` elsewhere. That is practical, but not strict
  portable C89.

## Next priorities

The main user-visible gaps are session management, extension depth, and
higher-level TUI interaction surfaces. The TUI already has a dedicated model
picker and the persistent
component, overlay/focus, and differential rendering base needed for larger
interactive surfaces. The next TUI parity layer is reusable picker/editor
components, not more terminal redraw plumbing.

1. **Reusable editor and selectors.** Move the prompt editor and command
   autocomplete into component objects, then generalize the dedicated model
   picker into `SelectList` / `SettingsList`-style components for
   theme/thinking/session pickers.
2. **Session tree UI.** `/tree`, `/branch`, and `/branches` can render
   the JSONL entry tree, switch the active leaf, and absorb the branch
   being left via branch-summary entries, but there is no dedicated TUI
   tree selector surface yet.
3. **Branch-aware compaction.** Use sibling context when choosing and building
   compactions, beyond preserving siblings in the session tree.
4. **Extension provider registration.** The Lua provider registry exists,
   but public registration/unregistration contracts need to be frozen before
   extensions can add providers safely.
5. **RPC mode.** JSONL over stdin/stdout reusing the same runtime
   and observer.
