-- psi.commands: slash-command dispatch.
--
-- Built-in commands return a records.command_action via one of two
-- channels:
--   * self-contained (kind="print") — rendered directly
--   * action-kinds that the REPL dispatcher in modes.lua knows how to
--     handle (set-model, new-session, resume, reload, export, name,
--     quit). TUI mode handles print/compact directly and can route
--     extension-defined action kinds through psi.tui handlers.
--
-- Extension-registered commands (psi.commands.register(name, handler))
-- are consulted last, after built-ins.

local records = require("psi.records")
local prelude = require("psi.prelude")
local keybindings = require("psi.keybindings")
local session = require("psi.session_manager")
local thinking = require("psi.thinking")
local clipboard = require("psi.clipboard")

local M = {}

local COMPACT_DEFAULT = 12
local BUILTIN_TUI_EXTENSIONS = {
  "vim_keybindings",
  "osc52_clipboard",
}

-- ---------- parsers ----------

local function arg_after(line, prefix)
  return prelude.trim(line:sub(#prefix + 1))
end

local function starts_word(line, word)
  if not prelude.starts_with(line, word) then
    return false
  end
  if #line == #word then
    return true
  end
  local ch = line:sub(#word + 1, #word + 1)
  return ch == " " or ch == "\t"
end

local function parse_compact_count(line)
  local rest = arg_after(line, "/compact")
  if #rest == 0 then
    return COMPACT_DEFAULT
  end
  return tonumber(rest) or COMPACT_DEFAULT
end

local function parse_fork_count(line)
  local rest = arg_after(line, "/fork")
  if #rest == 0 then
    return psi.session_message_count()
  end
  return tonumber(rest) or psi.session_message_count()
end

local function split_first_word(text)
  text = prelude.trim(text or "")
  local first, rest = text:match("^(%S+)%s*(.*)$")
  return first or "", rest or ""
end

local VALID_REASONING_EFFORTS = {
  off = true,
  minimal = true,
  low = true,
  medium = true,
  high = true,
  xhigh = true,
  none = true,
}

local function normalize_reasoning_effort(value)
  value = prelude.trim(value or "")
  if value == "" then
    return nil
  end
  value = value:lower()
  return VALID_REASONING_EFFORTS[value] and value or nil
end

local function cmd_set(rest)
  local key, value = split_first_word(rest)
  key = key:lower():gsub("_", "-")
  if key == "" then
    return records.new_command_action(
      "print",
      "usage: /set effort <off|minimal|low|medium|high|xhigh|none>"
    )
  end
  if key == "effort" or key == "reasoning" or key == "reasoning-effort" then
    local effort = normalize_reasoning_effort(value)
    if not effort then
      return records.new_command_action(
        "print",
        "usage: /set effort <off|minimal|low|medium|high|xhigh|none>"
      )
    end
    return records.new_command_action("set-reasoning-effort", effort)
  end
  return records.new_command_action("print", "unknown setting: " .. key)
end

local function cmd_thinking(rest)
  local level = thinking.normalize(rest)
  if not level then
    return records.new_command_action(
      "print",
      "usage: /thinking <off|minimal|low|medium|high|xhigh>"
    )
  end
  return records.new_command_action("set-thinking", level)
end

local function copy_auth_url(url)
  local copied = clipboard.write_osc52(url, { source = "openai-codex-login" })
  return copied and true or false
end

local function fork_output_path()
  local id = psi.session_id() or tostring(os.time())
  return "sessions/fork-" .. id .. "-" .. tostring(os.time()) .. ".jsonl"
end

-- /clone writes a full copy of the current session at the current
-- position. Mirrors pi's /clone ("duplicate session at current
-- position") and differs from /fork, which keeps the first N entries
-- only. Implementation reuses session.fork(total, out_path) — fork
-- with at_count = message_count is the natural full-session dump.
local function clone_output_path()
  local id = psi.session_id() or tostring(os.time())
  return "sessions/clone-" .. id .. "-" .. tostring(os.time()) .. ".jsonl"
end

-- ---------- session status (/session) ----------

local function last_assistant_summary()
  local msgs = psi.session_messages()
  for i = #msgs, 1, -1 do
    if msgs[i].role == "assistant" then
      local body = prelude.safe_json_decode(msgs[i].data, nil)
      if type(body) == "table" and type(body.message) == "table" then
        return body.message
      end
    end
  end
  return nil
end

local function session_status()
  local lines = {}
  local name = session.display_name and session.display_name() or nil
  if name and name ~= "" then
    lines[#lines + 1] = "name:      " .. name
  end
  lines[#lines + 1] = "id:        " .. tostring(psi.session_id() or "-")
  local path = psi.session_path() or ""
  if path ~= "" then
    lines[#lines + 1] = "file:      " .. path
  end
  lines[#lines + 1] = "messages:  " .. tostring(psi.session_message_count())
  local last = last_assistant_summary()
  if last then
    lines[#lines + 1] = "provider:  " .. tostring(last.provider or "-")
    lines[#lines + 1] = "model:     " .. tostring(last.model or "-")
    if last.usage then
      lines[#lines + 1] = string.format(
        "usage:     in=%d out=%d cacheRead=%d cacheWrite=%d total=%d",
        last.usage.input or 0,
        last.usage.output or 0,
        last.usage.cacheRead or 0,
        last.usage.cacheWrite or 0,
        last.usage.totalTokens or 0
      )
    end
  end
  return table.concat(lines, "\n")
end

-- ---------- clipboard (/copy) ----------

local function last_assistant_text()
  local last = last_assistant_summary()
  if not last then
    return nil
  end
  local text = ""
  if type(last.content) == "table" then
    for _, b in ipairs(last.content) do
      if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
        text = text == "" and b.text or (text .. b.text)
      end
    end
  end
  return text
end

local function cmd_copy()
  local text = last_assistant_text()
  if not text or text == "" then
    return records.new_command_action("print", "no assistant message to copy")
  end
  local ok, tool = clipboard.write(text, { source = "slash-copy" })
  if ok then
    return records.new_command_action("print", string.format("copied %d chars via %s", #text, tool))
  end
  return records.new_command_action(
    "print",
    "clipboard unavailable: " .. tostring(tool or "osc52 unavailable")
  )
end

-- ---------- markdown export (/export) ----------

local function render_markdown_session()
  local lines = {}
  local add = function(s)
    lines[#lines + 1] = s
  end
  add("# Session " .. tostring(psi.session_id() or "-"))
  local path = psi.session_path() or ""
  if path ~= "" then
    add("- **file**: " .. path)
  end
  add("- **generated**: " .. prelude.iso_timestamp())
  add("")
  for _, m in ipairs(psi.session_messages()) do
    local body = prelude.safe_json_decode(m.data, nil)
    local msg = type(body) == "table" and body.message or nil
    if m.role == "user" and msg then
      add("## User")
      add("")
      add(m.text or "")
      add("")
    elseif m.role == "assistant" and msg then
      local model = msg.model or "?"
      local u = msg.usage or {}
      local stop = msg.stopReason or "-"
      add(
        string.format(
          "## Assistant — %s (stop=%s, in=%d out=%d)",
          model,
          stop,
          u.input or 0,
          u.output or 0
        )
      )
      add("")
      for _, b in ipairs(msg.content or {}) do
        if type(b) == "table" then
          if b.type == "text" then
            add(b.text or "")
            add("")
          elseif b.type == "toolCall" then
            add(string.format("### Tool call: `%s` (id=%s)", b.name or "?", b.id or "?"))
            add("```json")
            add(psi.json_encode(b.arguments or {}))
            add("```")
            add("")
          end
        end
      end
    elseif m.role == "tool-result" and msg then
      add(
        string.format(
          "### Tool result: `%s` (id=%s%s)",
          msg.toolName or "?",
          msg.toolCallId or "?",
          msg.isError and ", error" or ""
        )
      )
      add("```")
      add(m.text or "")
      add("```")
      add("")
    elseif m.role == "compaction-summary" then
      add("## Compaction summary")
      add("")
      add(m.text or "")
      add("")
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

local function default_export_path()
  local id = psi.session_id() or tostring(os.time())
  return "sessions/" .. id .. ".md"
end

local function cmd_export(rest)
  local path = rest ~= "" and rest or default_export_path()
  local content = render_markdown_session()
  if not psi.mkdir_parent(path) then
    return records.new_command_action("print", "export failed: could not create parent directory")
  end
  local ok = psi.file_write(path, content)
  if ok then
    return records.new_command_action(
      "print",
      string.format("exported %d chars to %s", #content, path)
    )
  end
  return records.new_command_action("print", "export failed: " .. path)
end

-- /new, /clear, /reload are side-effect-only commands. Running them in
-- slash_commands.lua and returning a plain "print" action lets them work in
-- both the REPL and the TUI uniformly — the TUI's C dispatcher only
-- understands "print" and "compact" kinds, so everything else must
-- resolve here.
local function cmd_new_session()
  psi.session_clear()
  session.reset_entry_chain()
  if session.set_display_name then
    session.set_display_name(nil)
  end
  psi.session_set_id(prelude.uuid_short())
  if psi.context and psi.context.reset_usage then
    psi.context.reset_usage()
  end
  psi.session_set_path(nil)
  session.ensure_default_path()
  return records.new_command_action("print", "new session id=" .. tostring(psi.session_id() or "-"))
end

local function cmd_reload()
  if psi.settings and psi.settings.reload then
    pcall(psi.settings.reload)
  end
  if psi.extensions then
    for _, name in ipairs(BUILTIN_TUI_EXTENSIONS) do
      local extension = psi.extensions[name]
      if extension and extension.disable then
        pcall(extension.disable, psi)
      end
    end
  end
  if psi.tui then
    if psi.tui.clear_key_handlers then
      pcall(psi.tui.clear_key_handlers)
    end
    if psi.tui.clear_status_hooks then
      pcall(psi.tui.clear_status_hooks)
    end
    if psi.tui.clear_clipboard_writers then
      pcall(psi.tui.clear_clipboard_writers)
    end
  end
  if type(psi.install_builtin_extensions) == "function" then
    pcall(psi.install_builtin_extensions)
  end
  if type(psi.load_extensions) == "function" then
    local ok, err = pcall(psi.load_extensions)
    if not ok then
      return records.new_command_action("print", "reload failed: " .. tostring(err))
    end
  end
  if psi.theme and psi.theme.apply_configured then
    pcall(psi.theme.apply_configured, { preserve_current = true })
  end
  -- Prompt templates are cheap to rescan and usually edited side-by-
  -- side with extensions; reloading them here lets users iterate on
  -- a template.md without restarting psi.
  if psi.prompt_templates and psi.prompt_templates.load then
    pcall(psi.prompt_templates.load)
  end
  if keybindings.reload then
    pcall(keybindings.reload)
  end
  if psi.tui and psi.tui.run_startup_hooks then
    pcall(psi.tui.run_startup_hooks, { reason = "reload" })
  end
  return records.new_command_action("print", "extensions reloaded")
end

local function rainbow_fg(bg)
  bg = tonumber(bg) or 0
  if bg < 16 then
    return (bg == 0 or bg == 1 or bg == 2 or bg == 4 or bg == 5 or bg == 8) and 15 or 16
  end
  if bg >= 232 then
    return bg < 244 and 15 or 16
  end
  local n = bg - 16
  local b = n % 6
  local g = math.floor(n / 6) % 6
  local r = math.floor(n / 36) % 6
  local function level(v)
    return v == 0 and 0 or (55 + (v * 40))
  end
  local luminance = (0.2126 * level(r)) + (0.7152 * level(g)) + (0.0722 * level(b))
  return luminance < 140 and 15 or 16
end

local function rainbow_color(code, text)
  return string.char(27) .. "[" .. code .. "m" .. text .. string.char(27) .. "[0m"
end

local function rainbow_line(start_code, end_code, cols)
  local cells = {}
  for code = start_code, end_code do
    cells[#cells + 1] = rainbow_color(
      "38;5;" .. tostring(rainbow_fg(code)) .. ";48;5;" .. tostring(code),
      string.format("%03d ", code)
    )
    if #cells == cols then
      break
    end
  end
  return table.concat(cells)
end

local function cmd_rainbow()
  local lines = {
    "xterm 256 background swatches (/rainbow)",
  }
  local code = 0
  while code <= 255 do
    lines[#lines + 1] = rainbow_line(code, math.min(255, code + 15), 16)
    code = code + 16
  end
  return records.new_command_action("ansi-print", table.concat(lines, "\n"))
end

local function queue_summary()
  local agent = require("psi.agent_session")
  local items = agent.pending_messages()
  if #items == 0 then
    return "queue is empty"
  end
  local lines = { "queued messages" }
  for _, item in ipairs(items) do
    local text = (item.text or ""):gsub("%s+", " ")
    if #text > 72 then
      text = text:sub(1, 69) .. "..."
    end
    lines[#lines + 1] = string.format("  %d. [%s] %s", item.index, item.kind, text)
  end
  return table.concat(lines, "\n")
end

local function cmd_queue(rest)
  local agent = require("psi.agent_session")
  rest = prelude.trim(rest or "")
  if rest == "" or rest == "list" then
    return records.new_command_action("print", queue_summary())
  end
  if rest == "clear" then
    local n = agent.pending_message_count()
    agent.clear_queues()
    return records.new_command_action("print", "cleared " .. tostring(n) .. " queued message(s)")
  end
  local drop = rest:match("^drop%s+(%d+)$") or rest:match("^remove%s+(%d+)$")
  if drop then
    local removed = agent.remove_pending(tonumber(drop))
    if removed == nil then
      return records.new_command_action("print", "no queued message at " .. tostring(drop))
    end
    return records.new_command_action("print", "removed queued message " .. tostring(drop))
  end
  local edit_index, edit_text = rest:match("^edit%s+(%d+)%s+(.+)$")
  if edit_index then
    if agent.replace_pending(tonumber(edit_index), edit_text) then
      return records.new_command_action("print", "updated queued message " .. tostring(edit_index))
    end
    return records.new_command_action("print", "no queued message at " .. tostring(edit_index))
  end
  return records.new_command_action("print", "usage: /queue [list|clear|drop N|edit N text]")
end

-- ---------- dispatcher + registry ----------

local BUILTIN_COMMANDS = {
  {
    name = "help",
    aliases = { "h" },
    description = "Show available commands",
  },
  {
    name = "hotkeys",
    description = "Show keyboard shortcuts",
  },
  {
    name = "quit",
    aliases = { "q", ":quit", ":q" },
    description = "Exit the shell",
  },
  {
    name = "session",
    description = "Show current session info",
  },
  {
    name = "new",
    aliases = { "clear" },
    description = "Start a fresh session in place",
  },
  {
    name = "resume",
    argument_hint = "<path>",
    description = "Load a session file from disk",
  },
  {
    name = "import",
    argument_hint = "<path>",
    description = "Import a JSONL session",
  },
  {
    name = "name",
    argument_hint = "<text>",
    description = "Set the session display name",
  },
  {
    name = "model",
    argument_hint = "<spec>",
    description = "Switch model mid-session",
  },
  {
    name = "set",
    argument_hint = "<setting> <value>",
    description = "Set runtime options",
  },
  {
    name = "thinking",
    argument_hint = "<level>",
    description = "Set reasoning level",
  },
  {
    name = "login",
    argument_hint = "<provider>",
    description = "Authenticate an OAuth provider",
  },
  {
    name = "copy",
    description = "Copy the last assistant message to the clipboard",
  },
  {
    name = "export",
    argument_hint = "[path]",
    description = "Write the session as markdown",
  },
  {
    name = "compact",
    argument_hint = "[N]",
    description = "Summarize older context, keeping recent messages",
  },
  {
    name = "fork",
    argument_hint = "[N]",
    description = "Save the first N entries to a new session file",
  },
  {
    name = "clone",
    argument_hint = "[path]",
    description = "Duplicate the current session at its current position",
  },
  {
    name = "branch",
    argument_hint = "[entry-id]",
    description = "Show the session tree or switch the active branch leaf",
  },
  {
    name = "branches",
    description = "Show the session tree",
  },
  {
    name = "reload",
    description = "Reload extensions, prompt templates, and keybindings",
  },
  {
    name = "rainbow",
    description = "Show all 256 terminal background colors",
  },
  {
    name = "queue",
    argument_hint = "[list|clear|drop N|edit N text]",
    description = "Inspect or edit queued messages",
  },
  {
    name = "system-prompt",
    description = "Print the current coding-agent system prompt",
  },
}

local registered = {}
local registered_version = 0
local registered_sorted_cache = nil
local registered_sorted_version = -1

local function normalize_command_name(name)
  if type(name) ~= "string" then
    return nil
  end
  name = name:gsub("^/", "")
  return name ~= "" and name or nil
end

function M.register(name, handler, opts)
  if type(handler) == "table" and opts == nil then
    opts = handler
    handler = opts.handler
  end
  name = normalize_command_name(name)
  if not name or type(handler) ~= "function" then
    return
  end
  opts = type(opts) == "table" and opts or {}
  registered[name] = {
    name = name,
    handler = handler,
    description = opts.description,
    argument_hint = opts.argument_hint or opts["argument-hint"],
  }
  registered_version = registered_version + 1
end

function M.unregister(name)
  name = normalize_command_name(name)
  if not name then
    return
  end
  if registered[name] ~= nil then
    registered[name] = nil
    registered_version = registered_version + 1
  end
end

function M.builtin_commands()
  local out = {}
  for i, cmd in ipairs(BUILTIN_COMMANDS) do
    out[i] = cmd
  end
  return out
end

function M.registered_commands()
  if registered_sorted_cache and registered_sorted_version == registered_version then
    return registered_sorted_cache
  end
  local out = {}
  for _, cmd in pairs(registered) do
    out[#out + 1] = {
      name = cmd.name,
      description = cmd.description,
      argument_hint = cmd.argument_hint,
    }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  registered_sorted_cache = out
  registered_sorted_version = registered_version
  return out
end

local function append_suggestion(out, seen, cmd, source, name, alias_of)
  if type(cmd) ~= "table" or type(name) ~= "string" or name == "" or seen[name] then
    return
  end
  seen[name] = true
  out[#out + 1] = {
    name = name,
    description = cmd.description,
    argument_hint = cmd.argument_hint,
    source = source,
    alias_of = alias_of,
  }
end

local function command_matches(name, prefix)
  return prefix == "" or name:sub(1, #prefix) == prefix
end

local prompt_templates_module = nil
local function get_prompt_templates()
  if prompt_templates_module == nil then
    local ok, mod = pcall(require, "psi.prompt_templates")
    prompt_templates_module = (ok and mod) or false
  end
  return prompt_templates_module or nil
end

local suggestions_cache_text = nil
local suggestions_cache_limit = nil
local suggestions_cache_registered_version = -1
local suggestions_cache_templates_version = -1
local suggestions_cache_result = nil

function M.command_suggestions(text, limit)
  if type(text) ~= "string" or text:sub(1, 1) ~= "/" then
    return {}
  end
  local prefix = text:sub(2)
  if prefix:find("%s") then
    return {}
  end

  limit = tonumber(limit) or 32
  local templates = get_prompt_templates()
  local templates_version = (templates and templates.version and templates.version()) or 0

  if
    suggestions_cache_result
    and suggestions_cache_text == text
    and suggestions_cache_limit == limit
    and suggestions_cache_registered_version == registered_version
    and suggestions_cache_templates_version == templates_version
  then
    return suggestions_cache_result
  end

  local out = {}
  local seen = {}

  for _, cmd in ipairs(BUILTIN_COMMANDS) do
    if command_matches(cmd.name, prefix) then
      append_suggestion(out, seen, cmd, "built-in", cmd.name)
    end
    for _, alias in ipairs(cmd.aliases or {}) do
      if alias:sub(1, 1) ~= ":" and command_matches(alias, prefix) then
        append_suggestion(out, seen, cmd, "built-in", alias, cmd.name)
      end
    end
  end

  for _, cmd in ipairs(M.registered_commands()) do
    if command_matches(cmd.name, prefix) then
      append_suggestion(out, seen, cmd, "extension", cmd.name)
    end
  end

  if templates and templates.list then
    for _, tmpl in ipairs(templates.list()) do
      if command_matches(tmpl.name, prefix) then
        append_suggestion(out, seen, tmpl, "prompt", tmpl.name)
      end
    end
  end

  table.sort(out, function(a, b)
    if a.name == b.name then
      return (a.source or "") < (b.source or "")
    end
    return a.name < b.name
  end)

  for i = #out, limit + 1, -1 do
    out[i] = nil
  end

  suggestions_cache_text = text
  suggestions_cache_limit = limit
  suggestions_cache_registered_version = registered_version
  suggestions_cache_templates_version = templates_version
  suggestions_cache_result = out
  return out
end

local function command_invocation(cmd)
  local hint = cmd.argument_hint and (" " .. cmd.argument_hint) or ""
  return "/" .. cmd.name .. hint
end

local function append_command_lines(lines, commands)
  local width = 0
  for _, cmd in ipairs(commands) do
    width = math.max(width, #command_invocation(cmd))
  end
  width = math.max(width, 16)
  for _, cmd in ipairs(commands) do
    local aliases = {}
    for _, alias in ipairs(cmd.aliases or {}) do
      aliases[#aliases + 1] = alias:sub(1, 1) == ":" and alias or ("/" .. alias)
    end
    local desc = cmd.description or ""
    if #aliases > 0 then
      desc = desc .. " (aliases: " .. table.concat(aliases, ", ") .. ")"
    end
    lines[#lines + 1] =
      string.format("  %-" .. tostring(width) .. "s  %s\n", command_invocation(cmd), desc)
  end
end

function M.help_text()
  local lines = { "available commands\n", "\nbuilt-ins:\n" }
  append_command_lines(lines, BUILTIN_COMMANDS)

  local ext = M.registered_commands()
  if #ext > 0 then
    lines[#lines + 1] = "\nextensions:\n"
    append_command_lines(lines, ext)
  end

  local ok, templates = pcall(require, "psi.prompt_templates")
  if ok and templates and templates.help_lines then
    local template_help = templates.help_lines()
    if type(template_help) == "string" and template_help ~= "" then
      lines[#lines + 1] = "\n"
      lines[#lines + 1] = template_help
    end
  end

  return table.concat(lines):gsub("%s+$", "")
end

local function dispatch_registered(line)
  local first, rest = line:match("^/(%S+)%s*(.*)$")
  if not first then
    return nil
  end
  local command = registered[first]
  if not command then
    return nil
  end
  local ok, result = pcall(command.handler, rest or "", line)
  if not ok then
    io.stderr:write("psi.commands: /" .. first .. " failed: " .. tostring(result) .. "\n")
    return records.new_command_action("print", "command /" .. first .. " failed")
  end
  return result
end

local function is_quit(line)
  return line == "/quit" or line == "/q" or line == ":quit" or line == ":q"
end

function M.handle(line)
  if line == "/help" or line == "/h" then
    return records.new_command_action("print", M.help_text())
  end
  if line == "/hotkeys" then
    return records.new_command_action("print", keybindings.hotkeys_text())
  end
  if is_quit(line) then
    return records.new_command_action("quit", nil)
  end
  if line == "/session" then
    return records.new_command_action("print", session_status())
  end
  if line == "/system-prompt" then
    local prompt = require("psi.prompt")
    return records.new_command_action("print", prompt.system_prompt())
  end
  if line == "/copy" then
    return cmd_copy()
  end
  if line == "/new" or line == "/clear" then
    return cmd_new_session()
  end
  if line == "/reload" then
    return cmd_reload()
  end
  if line == "/rainbow" then
    return cmd_rainbow()
  end
  if starts_word(line, "/queue") then
    return cmd_queue(arg_after(line, "/queue"))
  end
  if starts_word(line, "/model") then
    local spec = arg_after(line, "/model")
    if spec == "" then
      return records.new_command_action(
        "print",
        "usage: /model <spec> (e.g. ollama/llama3.1:latest)"
      )
    end
    return records.new_command_action("set-model", spec)
  end
  if starts_word(line, "/set") then
    return cmd_set(arg_after(line, "/set"))
  end
  if starts_word(line, "/thinking") then
    return cmd_thinking(arg_after(line, "/thinking"))
  end
  if starts_word(line, "/login") then
    local provider, input = split_first_word(arg_after(line, "/login"))
    if provider == "" then
      provider = "openai-codex"
    end
    if provider ~= "openai-codex" then
      return records.new_command_action("print", "unsupported OAuth provider: " .. provider)
    end
    local oauth = require("psi.providers.oauth_openai_codex")
    local ok, result
    if input ~= "" then
      ok, result = oauth.finish_login(input)
    else
      local flow = oauth.begin_login()
      local copied = copy_auth_url(flow.url)
      ok = true
      local lines = {
        "Open this URL in your browser:",
        "",
        flow.url,
        "",
      }
      if copied then
        lines[#lines + 1] = "Copied auth URL to clipboard via OSC 52."
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = "Then paste the final redirect URL or authorization code with:"
      lines[#lines + 1] = "/login openai-codex <redirect-url-or-code>"
      result = table.concat(lines, "\n")
    end
    return records.new_command_action(
      "print",
      ok and result or ("login failed: " .. tostring(result))
    )
  end
  if starts_word(line, "/resume") then
    local path = arg_after(line, "/resume")
    if path == "" then
      return records.new_command_action("print", "usage: /resume <path>")
    end
    return records.new_command_action("resume", path)
  end
  if starts_word(line, "/import") then
    -- Alias for /resume: pi names it /import when loading a
    -- JSONL session from another source (another project, a
    -- shared transcript, etc.). Semantically identical for psi.
    local path = arg_after(line, "/import")
    if path == "" then
      return records.new_command_action("print", "usage: /import <path>")
    end
    return records.new_command_action("resume", path)
  end
  if starts_word(line, "/export") then
    local path = arg_after(line, "/export")
    return cmd_export(path)
  end
  if starts_word(line, "/name") then
    local name = arg_after(line, "/name")
    return records.new_command_action("name", name)
  end
  if starts_word(line, "/compact") then
    return records.new_command_action("compact", parse_compact_count(line))
  end
  if starts_word(line, "/fork") then
    local keep = parse_fork_count(line)
    local out = fork_output_path()
    local ok = session.fork(keep, out)
    local msg = ok and ("forked " .. tostring(keep) .. " entries to " .. out) or "fork failed"
    return records.new_command_action("print", msg)
  end
  if starts_word(line, "/clone") then
    local rest = arg_after(line, "/clone")
    local out = (rest ~= "" and rest) or clone_output_path()
    local total = psi.session_message_count()
    local ok = session.fork(total, out)
    local msg = ok and string.format("cloned %d entries to %s", total, out) or "clone failed"
    return records.new_command_action("print", msg)
  end
  if starts_word(line, "/branch") then
    local rest = arg_after(line, "/branch")
    if rest == "" then
      return records.new_command_action("print", session.branch_tree_text())
    end
    local ok, result = session.branch(rest)
    if not ok then
      return records.new_command_action("print", "branch failed: " .. tostring(result))
    end
    return records.new_command_action(
      "print",
      "active branch leaf: " .. tostring(result) .. "\n" .. session.branch_tree_text()
    )
  end
  if line == "/branches" then
    return records.new_command_action("print", session.branch_tree_text())
  end
  local registered_action = dispatch_registered(line)
  if registered_action ~= nil then
    return registered_action
  end

  -- Prompt template fallback: `/foo args…` where foo.md was loaded
  -- from ~/.config/psi/prompts/ (or project/./.psi/prompts/) is
  -- treated like a user turn whose text is the expanded template
  -- body. Returns an "expand" action so the caller (REPL or TUI)
  -- submits it as a turn rather than printing it.
  if psi.prompt_templates and psi.prompt_templates.expand then
    local expanded = psi.prompt_templates.expand(line)
    if type(expanded) == "string" and expanded ~= "" then
      return records.new_command_action("expand", expanded)
    end
  end

  return nil
end

-- Bridge for C (TUI): returns nil or a {kind-string, payload} sequence.
function M.handle_command_list(line)
  local action = M.handle(line)
  if not action then
    return nil
  end
  return records.command_action_to_list(action)
end

return M
