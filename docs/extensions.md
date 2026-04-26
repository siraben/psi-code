# psi extensions

psi has a small, Lua-native extension surface. An extension is a single
`.lua` file that returns a function; on startup psi discovers and invokes
it with the `psi` global. From there an extension can register tools,
subscribe to events, and add slash commands — the same APIs psi uses
internally.

This document codifies the **stable API surface** and the initial **event
catalog**. Anything not documented here is internal and may change.

---

## Discovery

At boot, psi scans three locations in order (earlier entries win on
conflicts; later ones see the cumulative `psi` state):

1. `$PSI_EXTENSIONS_DIR` (colon-separated list of directories)
2. `~/.config/psi/extensions/`
3. `./.psi/extensions/` (project-local)

Every `*.lua` file in each directory is `dofile`'d. If it returns a
function, psi invokes it with the `psi` global. Extension load failures
are logged to stderr and don't abort psi.

## Extension skeleton

```lua
-- ~/.config/psi/extensions/hello.lua
return function(psi)
  -- register a tool
  psi.tools.register(psi.records.new_tool(
    "hello",                                  -- name (LLM-visible)
    "Greet someone by name.",                 -- description
    "Say hello: input { who: string }",       -- prompt_snippet
    {},                                       -- guidelines (strings)
    {                                         -- JSON-schema input
      type = "object",
      properties = { who = { type = "string" } },
      required = { "who" },
    },
    function(input)                           -- impl(input) -> ToolResult
      return psi.records.new_tool_result(
        true, "hello", nil, { greeting = "hi, " .. input.who })
    end
  ))

  -- subscribe to a lifecycle event
  psi.events.on("turn-end", function(payload)
    io.stderr:write(("[hello] turn ended, %d chars\n"):format(#(payload.text or "")))
  end)

  -- add a slash command
  psi.commands.register("greet", function(rest)
    return psi.records.new_command_action(
      "print", "hi, " .. (rest ~= "" and rest or "friend"))
  end)
end
```

---

## Stable API surface

Everything below is guaranteed not to break compatibility within a minor
version. Experimental or internal helpers live off the `psi` global but
are not listed here and may change without notice.

### Tools — `psi.tools`

| API | Notes |
|---|---|
| `psi.tools.register(tool)` | Add or overwrite a tool in the registry. |
| `psi.tools.all()` | Array of all registered tools, in registration order. |
| `psi.tools.find(name)` | Lookup by name; returns the tool record or `nil`. |
| `psi.tools.add_before_hook(fn)` | `fn(name, input) -> ToolResult\|nil`. Returning non-nil short-circuits dispatch. |
| `psi.tools.add_after_hook(fn)` | `fn(name, input, result) -> ToolResult\|nil`. Returning non-nil replaces the result. |

**Tool record shape** (from `lua/psi/records.lua`):

```lua
{
  name            = "hello",          -- unique; registering the same
                                      -- name overwrites the prior entry
  description     = "...",            -- passed to the LLM
  prompt_snippet  = "...",            -- injected into the system prompt
  guidelines      = { "...", ... },   -- appended to system-prompt
                                      -- Guidelines section when the
                                      -- tool is selected
  input_schema    = { ... },          -- JSON-schema table
  impl            = function(input) end,
                                      -- input: parsed JSON table;
                                      -- returns a ToolResult
  execution_mode  = "parallel",       -- metadata; mutation tools may
                                      -- choose "sequential"
}
```

**`ToolResult`** (from `psi.records.new_tool_result(ok, tool, error, extras)`):

```lua
{
  ok     = true|false,
  tool   = "hello",
  error  = "...",                     -- string when ok=false
  -- plus every key of `extras` merged onto the result
}
```

**Input validators** (from `psi.tool_registry`):
- `psi.tool_registry.require_string(input, field)`
- `psi.tool_registry.optional_string(input, field, default)`
- `psi.tool_registry.optional_number(input, field, default)`
- `psi.tool_registry.optional_boolean(input, field, default)`

### Events — `psi.events`

| API | Notes |
|---|---|
| `psi.events.on(event, fn)` | Subscribe. `fn(payload)`. |
| `psi.events.off(event, fn)` | Unsubscribe a specific handler. |
| `psi.events.emit(event, payload)` | Fire an event (extensions can emit custom events). |
| `psi.events.handlers(event)` | Introspection; shallow copy. |

Semantics: synchronous dispatch in registration order, handler return
values ignored, errors swallowed per handler with a stderr log line.
Designed so adding a subscriber never interferes with rendering or
session state.

### Slash commands — `psi.commands`

| API | Notes |
|---|---|
| `psi.commands.register(name, handler)` | `handler(args_string, raw_line) -> CommandAction\|nil`. Overwrites on duplicate. |
| `psi.commands.unregister(name)` | Remove a previously registered command. |

Built-in commands take precedence over registered ones —
extensions cannot shadow them. Full list:

```
/help  /hotkeys  /quit (+ /q, :quit, :q)  /session  /system-prompt
/new (alias: /clear)  /reload  /copy
/resume <path>  /import <path>  (alias: /resume)
/name <text>  /model <spec>
/export [path]  /fork [N]  /clone [path]  /compact [N]
```

Canonical source: `lua/psi/prompt.lua M.HELP_TEXT`.

**CommandAction** (from `psi.records.new_command_action(kind, payload)`):
```lua
{ kind = "print" | "compact", payload = "..." | 12 }
```

### Render hooks — `psi.render.register_hook(event, fn)`

For extensions that want to *change the rendered terminal output*
(rather than just observe). Handlers receive a payload table and return
one of:

- `nil` / `false` — contribute nothing (observer-style).
- a `"string"` — appended to the running render in registration order.
- `{replace = true, text = "..."}` — **discards** everything earlier
  hooks in this chain contributed and starts over with `text`.
  Subsequent hooks in the chain still append. Use this when you need
  to *replace* a built-in renderer rather than add alongside it (e.g.
  swap `read`'s default tool-result block for a numbered one).

Render-hook mutations only affect what the **user sees** on the
terminal. If you also want to change what the **model sees** (the
tool-result payload fed back into its context), use a
`psi.tools.add_after_hook` — see below. The two are independent.

`psi.render.events()` returns the list of event names the render
bridge dispatches (currently `before-turn`, `assistant-text`,
`tool-call`, `tool-result`, `after-turn`). Extensions can inspect this
rather than hard-coding names.

Most extensions should use `psi.events.on` instead. Use render hooks
only when you need to mutate the on-screen output.

**TUI mode:** `before-turn` and `after-turn` render-hook output is
surfaced as info entries in the transcript. `assistant-text` is *not*
piped through the hook chain in TUI (streamed tokens go straight to
the assistant-entry renderer); use the `assistant-text-delta` event
via `psi.events.on` if you need per-delta visibility.

**Do not use `io.stderr:write` from a hook running during a TUI
turn.** The TUI redirects stderr to `$XDG_STATE_HOME/psi/debug.log`
(default `~/.local/state/psi/debug.log`) while a turn is in flight so
provider/curl chatter doesn't corrupt the ncurses canvas. Bytes
written during the turn are appended to the log, not shown. To show
text in the transcript, return it as a string from a render hook; to
show text in the status bar, register a `psi.tui.register_status_hook`
(see below). Tail the debug log with `tail -F
~/.local/state/psi/debug.log` in another pane for diagnostics.

### Safe C primitives on `psi`

These are part of the stable surface:

| API | Notes |
|---|---|
| `psi.cwd()` | Current working directory string. |
| `psi.read_file(path)` / `psi.file_exists(path)` / `psi.file_write(path, content)` | Filesystem I/O. |
| `psi.current_date()` | `"YYYY-MM-DD"`. |
| `psi.is_aborted()` | `true` when Ctrl-C / Esc requested. Poll during long work. |
| `psi.json_encode(v)` / `psi.json_decode(s)` | JSON. |
| `psi.session_message_count()` / `psi.session_messages()` | Read current in-memory session. |
| `psi.embedded_doc(name)` / `psi.embedded_doc_names()` | Fetch doc files bundled into the binary (e.g. `README.md`). |
| `psi.embedded_source(name)` / `psi.embedded_source_names()` | Fetch the raw Lua source of an embedded module (e.g. `psi.render`). Useful for live introspection when there is no on-disk path. |
| `psi.tool_call(name, input)` | Dispatch a tool through the full before/after hook chain. **Prefer this over calling `tool.impl` directly** — `impl` skips hook processing (permissions, redaction, extension transforms). |
| `psi.tools.cancel(reason)` | Shorthand for a failure `ToolResult` used in before-hooks to short-circuit dispatch. Example: `tools.add_before_hook(function(n, i) if n == "bash" and i.command:find("rm %-rf") then return tools.cancel("refused") end end)`. |
| `psi.prompt.register_transformer(fn)` | Append a system-prompt rewriter. Receives the assembled prompt, returns a replacement (or `nil` to leave it). Runs after built-in assembly; transformers stack in registration order. |
| `psi.agent.set_model(name)` / `psi.agent.current_model(fallback)` | Switch the default model at runtime (any prefix psi understands: `anthropic/`, `ollama/`, `openrouter/`). Picked up on the *next* turn; the TUI status line reflects it immediately. Pass `nil` to clear. |
| `psi.tui.register_status_hook(fn)` | Append a short status-bar snippet. `fn()` is called on every redraw (must be cheap) and returns a string or nil. Useful for tokens/sec meters, background-task indicators, etc. Suppressed while an active status message is on screen. |
| `psi.tools.set_active(names)` / `get_active()` | Narrow the tool set offered to the model for subsequent turns. Pass a list of tool names to restrict; pass `nil` to clear the scope and restore all registered tools. Useful for skill-scoped agents (e.g. `tools.set_active({"read","grep"})` for a read-only investigation). |
| `psi.session.send_message(role, text)` | Inject a user or assistant message into the in-memory session without triggering a turn. `role` is `"user"` or `"assistant"`. Call `psi.session.save()` afterwards to persist. Replaces the former internal-only `append_user` / `append_assistant` for extension use. |
| `psi.session.append_custom(name, data)` | Persist extension data in the session file without adding it to model context. |
| `psi.session.append_custom_message(text, opts)` | Persist a model-visible custom message. `opts.role` may be `"user"` or `"assistant"`; `opts.hidden=true` keeps it out of provider context. |
| `psi.providers.all_providers()` / `all_models()` | Inspect the built-in provider/model registry. Provider registration exists internally but is not yet a stable extension API. |
| `psi.settings.get(path, default)` / `reload()` | Read layered JSON settings from `~/.config/psi/settings.json` and `./.psi/settings.json`. |
| `psi.resources.context_files()` | Discover global/project context files. Emits `resources_discover`. |
| `psi.prompt_templates.load()` / `list()` / `find(name)` / `expand(text)` | Loader + lookup + runtime expansion for user-authored slash-command templates. `/reload` reloads them. See "Prompt templates" below. |

### Prompt templates

Drop a `.md` file in any of:

- `$PSI_PROMPTS_DIR` (colon-separated list, env override)
- `$XDG_CONFIG_HOME/psi/prompts/` (default `~/.config/psi/prompts/`)
- `./.psi/prompts/` (project-local — overrides global on name collision)

…and typing `/<filename> args…` in the REPL or TUI expands the body
with bash-style argument substitution and sends the result as the
user's next turn. Filename minus `.md` becomes the slash-command name.

Frontmatter (optional, between leading `---` lines):

```markdown
---
description: short one-liner shown in /help
argument-hint: "<path> [limit]"
---
Review the file $1, paying attention to lines around $2.
Full args: $@ (aka $ARGUMENTS).
```

Argument placeholders (run on the body, not on the args):

| Pattern | Meaning |
|---|---|
| `$1`, `$2`, … | 1-indexed positional arg (empty string when absent) |
| `$@`, `$ARGUMENTS` | all args joined with single spaces |
| `${@:N}` | args from position N onwards |
| `${@:N:L}` | L args starting from N |

Argument parsing is bash-ish: whitespace-separated, single- and
double-quoted strings are preserved as one token.

Ported from pi-mono's `prompt-templates.ts` (MIT, (c) 2025 Mario Zechner).

Prelude helpers on `psi.prelude` (`trim`, `split`, `safe_json_decode`,
`safe_read`, `uuid_short`, `iso_timestamp`, `as_array`, `path_join`) are
stable as well.

---

## Event catalog

Every event is fired synchronously from the agent turn loop. Order is
defined below. Handlers must be fast — they run on the turn's critical
path.

Psi emits its historical hyphenated event names and aliases several of
them to pi-style underscore names (`turn_end`, `tool_execution_start`,
`after_provider_response`, etc.) for new extension code.

| Event | Firing site | Payload |
|---|---|---|
| `before-turn` | Before each streaming iteration in `anthropic.run_turn`. Also fires once per user prompt. | `{ text = "<user prompt>" }` (via render bridge) |
| `before-provider-request` | After context mutation and request-body assembly, before `http_stream_begin`. | `{ provider, model, body }` |
| `after-provider-response` | Right after the assistant message is saved, before tool dispatch or auto-compaction. | `{ usage, stop_reason, response_id, model }` |
| `assistant-text-delta` | Every streamed text chunk. High frequency. | `{ text = "<chunk>" }` |
| `tool-call-delta` | Every streamed chunk of a tool_use block's input JSON. | `{ id, partial_json }` |
| `thinking-delta` | Every streamed thinking-block chunk. **Anthropic provider only** — the Ollama loop doesn't emit thinking today. | `{ text }` |
| `tool-call` | Before a tool is dispatched. | `{ id, tool, input }` |
| `tool-result` | After a tool returns. | `{ id, tool, result }` |
| `assistant-text` | Per aggregated assistant text block (render-level). | `{ text }` |
| `turn-end` | Final event when a turn ends with no more tool_use (i.e. the full turn is done). | `{ text, model }` |
| `after-turn` | Right after `turn-end`, during render flush. | `{ text, ["assistant-streamed"] }` |
| `compaction-start` | Before `psi.session.do_compact` clears the in-memory session and appends the summary. Extensions (e.g. autosave) can flush current on-disk state before the rewrite. | `{ total, keep_recent, compacted }` |
| `compaction-end` | After the summary + kept tail are appended back. Pair with `compaction-start`; the summary text is included so loggers don't have to re-read the session. | `{ total, keep_recent, compacted, summary }` |
| `context` | Right before a provider request is built, once per turn iteration. **The `messages` table is mutable** — handlers may insert, remove, or replace entries and the edits hit the wire. Use for RAG injection, tool-result redaction, mid-context compression. | `{ messages, model, provider, system_prompt }` |
| `resources_discover` | During context/resource discovery before the system prompt is finalized. | `{ context_files, diagnostics }` |
| `session-start` | Fired once when a session is loaded (`source="load"`) or freshly created (`source="new"`). Extensions that own log files / counters / timers should initialise here instead of on the first `before-turn`. | `{ id, path, source, message_count }` |
| `session-shutdown` | Fired once, just before host teardown (TUI state free or REPL exit). Flush your state here — the Lua VM is still live. | `{ id, path, message_count }` |

Subscribe pattern:

```lua
psi.events.on("after-provider-response", function(p)
  io.stderr:write(("turn cost: in=%d out=%d cacheRead=%d\n"):format(
    p.usage.input_tokens or 0,
    p.usage.output_tokens or 0,
    p.usage.cache_read_input_tokens or 0))
end)
```

---

## Non-goals (today)

What we **intentionally** do not support yet — open tickets, not bugs:

- No `psi install` / package manager. Extensions are single-file drops.
- No TypeScript. Lua only.
- No provider registration (psi is Anthropic-only; revisit when we add a
  second provider).
- No sandboxing. Extensions run with full Lua and `psi` access — trust
  the files you install.
- No extension manifest, versioning, or compatibility checks.
- No hot reload.
- No MCP bridge.
- No extension-controlled system-prompt injection (future
  `system-prompt-build` event).
- pi ships ~27 events; psi starts with the 10 above. New ones will be
  added on demand.

---

## Internal, not stable

These are on the `psi` global but subject to change without notice:

- `psi.render.capture_frame` / `release_frame` / `lookup_frame`.
- `psi.anthropic.*` (internals of the turn loop).
- `psi.context` (token accounting — field names may shift).
- `psi.session.append_user` / `append_assistant` / `append_tool_result`
  (use `psi.events` to observe instead of calling these directly).
- Anything named starting with `_`.

If you find yourself reaching for one of these, consider opening an
issue — it likely points to a missing stable API.
