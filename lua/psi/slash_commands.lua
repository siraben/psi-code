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
local notice = require("psi.notice")
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

local function parse_tree_args(rest)
  rest = prelude.trim(rest or "")
  if rest == "" then
    return nil
  end
  local words = {}
  for word in rest:gmatch("%S+") do
    words[#words + 1] = word
  end
  local target = words[1]
  local summarize = false
  local custom = {}
  for i = 2, #words do
    local word = words[i]
    if word == "--summarize" or word == "-s" then
      summarize = true
    elseif word == "--no-summarize" then
      summarize = false
    else
      custom[#custom + 1] = word
    end
  end
  return {
    target = target,
    summarize = summarize,
    custom_instructions = table.concat(custom, " "),
  }
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

-- /theme lists the registered themes or switches the active one. This
-- mirrors pi's /theme command; psi ships pi-dark and pi-light.
local function cmd_theme(rest)
  local name = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local available = {}
  if psi.theme and psi.theme.names then
    local ok, names = pcall(psi.theme.names)
    if ok and type(names) == "table" then
      available = names
    end
  end
  if name == "" then
    local current = psi.theme and psi.theme.current_name and psi.theme.current_name() or "?"
    local lines = { "active theme: " .. tostring(current), "", "available themes:" }
    for _, n in ipairs(available) do
      lines[#lines + 1] = (n == current and "* " or "  ") .. n
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "usage: /theme <name>"
    return records.new_command_action("print", table.concat(lines, "\n"))
  end
  return records.new_command_action("set-theme", name)
end

local function copy_auth_url(url)
  local copied = clipboard.write_osc52(url, { source = "openai-codex-login" })
  return copied and true or false
end

local AUTH_METHODS = {
  {
    id = "oauth",
    type = "oauth",
    description = "Sign in with a provider account",
  },
  {
    id = "api-key",
    type = "api_key",
    description = "Store an API key or credential reference",
  },
}

local AUTH_METHOD_ALIASES = {
  oauth = "oauth",
  account = "oauth",
  subscription = "oauth",
  ["api-key"] = "api_key",
  api_key = "api_key",
  apikey = "api_key",
  key = "api_key",
}

local function auth_method_id(auth_type)
  return auth_type == "api_key" and "api-key" or auth_type
end

local function auth_method_label(auth_type)
  if auth_type == "api_key" then
    return "API key"
  end
  if auth_type == "oauth" then
    return "OAuth"
  end
  return "stored credential"
end

local function provider_auth_options(auth_type)
  local registry = require("psi.api_registry")
  local out = {}
  for _, registered in ipairs(registry.all_providers()) do
    local provider = registry.provider(registered.name)
    local auth = type(provider.auth) == "table" and provider.auth or {}
    for _, method in ipairs(AUTH_METHODS) do
      if (not auth_type or auth_type == method.type) and type(auth[method.type]) == "table" then
        out[#out + 1] = {
          provider = provider.name,
          name = provider.display_name or provider.name,
          auth_type = method.type,
          method = auth[method.type],
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.name == b.name then
      return a.auth_type < b.auth_type
    end
    return a.name < b.name
  end)
  return out
end

local function find_provider_auth_options(provider, auth_type)
  local out = {}
  for _, option in ipairs(provider_auth_options(auth_type)) do
    if option.provider == provider then
      out[#out + 1] = option
    end
  end
  return out
end

local function provider_display_name(provider)
  local registry = require("psi.api_registry")
  local spec = registry.provider(provider)
  return (spec and spec.display_name) or provider
end

local function auth_method_selection(provider_options)
  local lines = { "Select authentication method:" }
  for _, method in ipairs(AUTH_METHODS) do
    local available = false
    for _, option in ipairs(provider_options or provider_auth_options(method.type)) do
      if option.auth_type == method.type then
        available = true
        break
      end
    end
    if available then
      lines[#lines + 1] = string.format("  /login %-8s  %s", method.id, method.description)
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Choose a method or provider with Tab completion."
  return table.concat(lines, "\n")
end

local function provider_selection(auth_type)
  local options = provider_auth_options(auth_type)
  if #options == 0 then
    return "No " .. auth_method_label(auth_type) .. " providers are available."
  end
  local lines = { "Select " .. auth_method_label(auth_type) .. " provider:" }
  for _, option in ipairs(options) do
    lines[#lines + 1] =
      string.format("  /login %s %s  %s", auth_method_id(auth_type), option.provider, option.name)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Use Tab to complete provider names."
  return table.concat(lines, "\n")
end

local function api_key_login(option, input)
  local invocation = "/login " .. option.provider .. " <api-key-or-reference>"
  if input == "" then
    local lines = {
      "Configure " .. option.name .. " with an API key:",
      "  " .. invocation,
      "",
      "The value may be a literal key, $VAR/${VAR}, or !shell-command.",
      "It is stored in " .. require("psi.auth_storage").path() .. " with mode 0600.",
    }
    if option.method.env then
      lines[#lines + 1] = "Without a stored key, " .. option.method.env .. " remains supported."
    end
    return true, table.concat(lines, "\n")
  end

  local auth_storage = require("psi.auth_storage")
  local ok, err = auth_storage.set(option.provider, { type = "api_key", key = input })
  if not ok then
    return false, err
  end
  local lines = {
    "Saved API key for " .. option.name .. " to " .. auth_storage.path() .. ".",
    "The stored credential takes precedence over provider environment variables.",
    "Use /model " .. option.provider .. "/<model> to select a model.",
  }
  return true, table.concat(lines, "\n")
end

local function oauth_login(option, input)
  if type(option.method.module) ~= "string" then
    return false, "OAuth login is not implemented for " .. option.provider
  end
  local oauth = require(option.method.module)
  if input ~= "" then
    return oauth.finish_login(input)
  end

  local flow = oauth.begin_login()
  local copied = copy_auth_url(flow.url)
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
  lines[#lines + 1] = "Complete sign-in in the browser, then copy the final redirect URL or code."
  lines[#lines + 1] = "Paste it back into psi with:"
  lines[#lines + 1] = "/login " .. option.provider .. " <redirect-url-or-code>"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "psi uses manual paste so OAuth also works on small and headless hosts."
  return true, table.concat(lines, "\n")
end

local function cmd_login(rest)
  local first, tail = split_first_word(rest)
  if first == "" then
    return records.new_command_action("print", auth_method_selection())
  end

  local auth_type = AUTH_METHOD_ALIASES[first:lower()]
  local provider, input
  if auth_type then
    provider, input = split_first_word(tail)
    if provider == "" then
      return records.new_command_action("print", provider_selection(auth_type))
    end
  else
    provider = first
    input = tail
  end

  local options = find_provider_auth_options(provider, auth_type)
  if #options == 0 then
    local registry = require("psi.api_registry")
    local spec = registry.provider(provider)
    if spec and next(spec.auth or {}) == nil then
      return records.new_command_action(
        "print",
        provider_display_name(provider) .. " does not require login."
      )
    end
    local method_text = auth_type and (" for " .. auth_method_label(auth_type)) or ""
    return records.new_command_action(
      "print",
      "No login provider named '" .. provider .. "'" .. method_text .. ". Run /login to choose one."
    )
  end
  if #options > 1 then
    return records.new_command_action("print", auth_method_selection(options))
  end

  local option = options[1]
  local ok, result
  if option.auth_type == "api_key" then
    ok, result = api_key_login(option, input)
  else
    ok, result = oauth_login(option, input)
  end
  return records.new_command_action(
    "print",
    ok and result or ("login failed: " .. tostring(result))
  )
end

local function logout_selection()
  local auth_storage = require("psi.auth_storage")
  local stored, err = auth_storage.list()
  if not stored then
    return "Could not list stored credentials: " .. tostring(err)
  end
  if #stored == 0 then
    return "No stored credentials to remove. /logout only removes auth.json entries; environment variables and settings are unchanged."
  end
  local lines = { "Select stored credential to remove:" }
  for _, item in ipairs(stored) do
    lines[#lines + 1] = string.format(
      "  /logout %-16s  %s (%s)",
      item.provider,
      provider_display_name(item.provider),
      auth_method_label(item.type)
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] =
    "Only the selected auth.json entry is removed; environment variables and settings are unchanged."
  return table.concat(lines, "\n")
end

local function cmd_logout(rest)
  local provider, extra = split_first_word(rest)
  if provider == "" then
    return records.new_command_action("print", logout_selection())
  end
  if extra ~= "" then
    return records.new_command_action("print", "usage: /logout <provider>")
  end

  local auth_storage = require("psi.auth_storage")
  local stored, list_err = auth_storage.list()
  if not stored then
    return records.new_command_action("print", "logout failed: " .. tostring(list_err))
  end
  local stored_type = nil
  for _, item in ipairs(stored) do
    if item.provider == provider then
      stored_type = item.type
      break
    end
  end
  if not stored_type then
    return records.new_command_action(
      "print",
      "No stored credential for "
        .. provider
        .. ". /logout only removes auth.json entries; environment variables and settings are unchanged."
    )
  end

  local ok, err = auth_storage.remove(provider)
  if not ok then
    return records.new_command_action("print", "logout failed: " .. tostring(err))
  end
  local verb = "Removed stored credential for "
  if stored_type == "oauth" then
    verb = "Removed stored OAuth credential for "
  elseif stored_type == "api_key" then
    verb = "Removed stored API key for "
  end
  return records.new_command_action(
    "print",
    verb
      .. provider_display_name(provider)
      .. " from "
      .. auth_storage.path()
      .. ". Environment variables and settings are unchanged."
  )
end

local function fork_output_path()
  return session.new_session_file_path(psi.cwd and psi.cwd() or nil)
end

-- /clone writes a full copy of the current session at the current
-- position. Mirrors pi's /clone ("duplicate session at current
-- position") and differs from /fork, which keeps the first N entries
-- only. Implementation reuses session.fork(total, out_path) — fork
-- with at_count = message_count is the natural full-session dump.
local function clone_output_path()
  return session.new_session_file_path(psi.cwd and psi.cwd() or nil)
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
    elseif m.role == "branch-summary" then
      add("## Branch summary")
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

-- /trust inspects or persists the workspace trust decision for the
-- current directory. Applying a changed decision needs a restart:
-- extensions only load at boot.
local function cmd_trust(rest)
  local trust = require("psi.trust")
  local cwd = psi.cwd()
  if rest == "always" or rest == "never" then
    local ok, err = trust.remember(cwd, rest == "always")
    if not ok then
      return records.new_command_action("print", "could not save trust decision: " .. tostring(err))
    end
    return records.new_command_action(
      "print",
      "saved trust decision: "
        .. (rest == "always" and "trusted" or "untrusted")
        .. ". Restart psi for this to take effect."
    )
  end
  if rest ~= "" then
    return records.new_command_action("print", "usage: /trust [always|never]")
  end
  local stored = trust.stored(cwd)
  local lines = {
    "project trust",
    "  directory: " .. cwd,
    "  this session: " .. (psi.project_trusted and "trusted" or "untrusted"),
    "  saved decision: " .. (stored == nil and "none" or (stored and "trusted" or "untrusted")),
    "  .psi resources present: " .. (trust.has_project_resources(cwd) and "yes" or "no"),
  }
  return records.new_command_action("print", table.concat(lines, "\n"))
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
  if psi.tools and psi.tools.clear_hooks then
    pcall(psi.tools.clear_hooks)
  end
  if psi.session and psi.session.install_file_op_hook then
    pcall(psi.session.install_file_op_hook)
  end
  if psi.events and psi.events.clear then
    pcall(psi.events.clear)
  end
  if psi.prompt and psi.prompt.clear_transformers then
    pcall(psi.prompt.clear_transformers)
  end
  if type(psi.install_builtin_extensions) == "function" then
    pcall(psi.install_builtin_extensions)
  end
  if psi.mcp and psi.mcp.reload then
    pcall(psi.mcp.reload)
  end
  if psi.load_user_extensions ~= false and type(psi.load_extensions) == "function" then
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
  local modes = agent.queue_modes and agent.queue_modes() or {}
  local items = agent.pending_messages()
  if #items == 0 then
    return "queue is empty\nmodes: steering="
      .. tostring(modes.steering or "one-at-a-time")
      .. " follow-up="
      .. tostring(modes["follow-up"] or "one-at-a-time")
  end
  local lines = {
    "queued messages",
    "modes: steering=" .. tostring(modes.steering or "one-at-a-time") .. " follow-up=" .. tostring(
      modes["follow-up"] or "one-at-a-time"
    ),
  }
  for _, item in ipairs(items) do
    local text = (item.text or ""):gsub("%s+", " ")
    if #text > 72 then
      text = text:sub(1, 69) .. "..."
    end
    lines[#lines + 1] = string.format("  %d. [%s] %s", item.index, item.kind, text)
  end
  return table.concat(lines, "\n")
end

local function queue_kind_alias(kind)
  kind = tostring(kind or ""):lower():gsub("_", "-")
  if kind == "steer" or kind == "steering" then
    return "steering"
  end
  if kind == "follow" or kind == "followup" or kind == "follow-up" then
    return "follow-up"
  end
  return nil
end

local function queue_modes_summary()
  local agent = require("psi.agent_session")
  local modes = agent.queue_modes and agent.queue_modes() or {}
  return "queue modes\n  steering: "
    .. tostring(modes.steering or "one-at-a-time")
    .. "\n  follow-up: "
    .. tostring(modes["follow-up"] or "one-at-a-time")
end

local function queue_state_summary()
  local agent = require("psi.agent_session")
  local modes = agent.queue_modes and agent.queue_modes() or {}
  return "queue state\n  steeringMode: "
    .. tostring(modes.steering or "one-at-a-time")
    .. "\n  followUpMode: "
    .. tostring(modes["follow-up"] or "one-at-a-time")
    .. "\n  pendingMessageCount: "
    .. tostring(agent.pending_message_count())
end

local function set_queue_mode_action(kind, mode, usage)
  local agent = require("psi.agent_session")
  local ok, normalized_kind, normalized_mode = agent.set_queue_mode(kind, mode)
  if ok then
    return records.new_command_action(
      "print",
      "set " .. normalized_kind .. " queue mode to " .. normalized_mode
    )
  end
  return records.new_command_action("print", tostring(normalized_kind or usage))
end

local function clear_queue_action(kind)
  local agent = require("psi.agent_session")
  if kind == "all" then
    local n = agent.pending_message_count()
    agent.clear_queues()
    return records.new_command_action("print", "cleared " .. tostring(n) .. " queued message(s)")
  end
  if kind ~= nil and agent.clear_queue then
    local n = agent.clear_queue(kind) or 0
    return records.new_command_action(
      "print",
      "cleared " .. tostring(n) .. " " .. kind .. " queued message(s)"
    )
  end
  return records.new_command_action("print", "usage: /queue clear [steering|follow-up]")
end

local function cmd_queue(rest)
  local agent = require("psi.agent_session")
  rest = prelude.trim(rest or "")
  if rest == "" or rest == "list" or rest == "pending" or rest == "messages" then
    return records.new_command_action("print", queue_summary())
  end
  local verb, tail = split_first_word(rest)
  verb = tostring(verb or ""):lower():gsub("_", "-")
  tail = prelude.trim(tail or "")

  if verb == "help" then
    return records.new_command_action(
      "print",
      "usage: /queue [list|state|modes|mode KIND MODE|set-steering-mode MODE|set-follow-up-mode MODE|steer TEXT|follow-up TEXT|clear [KIND]|drop N|edit N text]"
    )
  end
  if verb == "modes" or (verb == "mode" and tail == "") then
    return records.new_command_action("print", queue_modes_summary())
  end
  if verb == "state" or verb == "status" then
    return records.new_command_action("print", queue_state_summary())
  end
  if verb == "count" then
    return records.new_command_action(
      "print",
      "pendingMessageCount: " .. tostring(agent.pending_message_count())
    )
  end
  if verb == "mode" then
    local kind, mode = split_first_word(tail)
    return set_queue_mode_action(
      kind,
      mode,
      "usage: /queue mode <steering|follow-up> <one-at-a-time|all>"
    )
  end
  if verb == "set-steering-mode" or verb == "steering-mode" then
    if tail == "" then
      return records.new_command_action(
        "print",
        "steeringMode: " .. tostring(agent.queue_mode("steering") or "one-at-a-time")
      )
    end
    return set_queue_mode_action(
      "steering",
      tail,
      "usage: /queue set-steering-mode <one-at-a-time|all>"
    )
  end
  if verb == "set-follow-up-mode" or verb == "follow-up-mode" then
    if tail == "" then
      return records.new_command_action(
        "print",
        "followUpMode: " .. tostring(agent.queue_mode("follow-up") or "one-at-a-time")
      )
    end
    return set_queue_mode_action(
      "follow-up",
      tail,
      "usage: /queue set-follow-up-mode <one-at-a-time|all>"
    )
  end
  if verb == "steer" or verb == "steering" then
    if tail == "" then
      return records.new_command_action("print", "usage: /queue steer <text>")
    end
    if agent.queue_steering(tail) then
      return records.new_command_action("print", "queued steering message")
    end
    return records.new_command_action("print", "failed to queue steering message")
  end
  if verb == "follow" or verb == "followup" or verb == "follow-up" then
    if tail == "" then
      return records.new_command_action("print", "usage: /queue follow-up <text>")
    end
    if agent.queue_follow_up(tail) then
      return records.new_command_action("print", "queued follow-up message")
    end
    return records.new_command_action("print", "failed to queue follow-up message")
  end
  if verb == "clear-all" then
    return clear_queue_action("all")
  end
  if verb == "clear-steering" then
    return clear_queue_action("steering")
  end
  if verb == "clear-follow-up" then
    return clear_queue_action("follow-up")
  end
  if verb == "clear" then
    local kind = queue_kind_alias(tail)
    if tail ~= "" and kind == nil then
      return clear_queue_action(nil)
    end
    return clear_queue_action(kind or "all")
  end
  local drop = rest:match("^drop%s+(%d+)$")
    or rest:match("^remove%s+(%d+)$")
    or rest:match("^rm%s+(%d+)$")
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
  return records.new_command_action(
    "print",
    "usage: /queue [list|state|modes|mode KIND MODE|set-steering-mode MODE|set-follow-up-mode MODE|steer TEXT|follow-up TEXT|clear [KIND]|drop N|edit N text]"
  )
end

-- ---------- self-documenting commands ----------

-- Resolve a user-typed key to the canonical psi.doc entry key. Users
-- type "/help" or "help"; tools as "read" or "tool:read"; primitives
-- as "psi.cwd" or "cwd"; keybindings as "tui.input.submit". The
-- resolver tries the input verbatim, then a few plausible prefixes.
local function resolve_doc_key(input)
  local doc = require("psi.doc")
  if doc.get(input) then
    return input
  end
  local prefixes = { "/", "psi.", "tool:", "provider:" }
  for _, prefix in ipairs(prefixes) do
    local key = prefix .. input
    if doc.get(key) then
      return key
    end
  end
  -- Strip leading "/" if user typed "/foo" but registry has "foo"
  -- (shouldn't happen for slash commands, but cheap to check).
  local trimmed = input:gsub("^/", "")
  if trimmed ~= input and doc.get(trimmed) then
    return trimmed
  end
  return nil
end

local function format_describe_entry(key, entry)
  local lines = {}
  lines[#lines + 1] = string.format("%s  [%s]", key, entry.kind)
  lines[#lines + 1] = ""
  if entry.doc and entry.doc ~= "" then
    lines[#lines + 1] = entry.doc
  else
    lines[#lines + 1] = "(no docstring)"
  end
  if entry.source and entry.source ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Defined in: " .. entry.source
  end
  if entry.kind == "tool" and entry.extra then
    if entry.extra.input_schema and entry.extra.input_schema.required then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Required input fields: "
        .. table.concat(entry.extra.input_schema.required, ", ")
    end
  end
  if entry.kind == "key" and entry.extra and entry.extra.default_keys then
    local kb = require("psi.keybindings")
    local resolved = kb.keys(entry.extra.id)
    if resolved and #resolved > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Bound keys: " .. table.concat(resolved, ", ")
    end
  end
  return table.concat(lines, "\n")
end

local function cmd_describe(rest)
  rest = prelude.trim(rest or "")
  if rest == "" then
    return records.new_command_action(
      "print",
      "usage: /describe <symbol>\n\n"
        .. "Examples: /describe /help, /describe psi.cwd, /describe tool:read,\n"
        .. "          /describe tui.input.submit, /describe provider:anthropic.\n\n"
        .. "See also: /apropos <pattern>"
    )
  end
  local doc = require("psi.doc")
  local key = resolve_doc_key(rest)
  if not key then
    return records.new_command_action(
      "print",
      "no entry for '" .. rest .. "'.  Try /apropos " .. rest
    )
  end
  return records.new_command_action("print", format_describe_entry(key, doc.get(key)))
end

local function cmd_apropos(rest)
  rest = prelude.trim(rest or "")
  if rest == "" then
    return records.new_command_action("print", "usage: /apropos <pattern>")
  end
  local doc = require("psi.doc")
  local hits = doc.apropos(rest)
  if #hits == 0 then
    return records.new_command_action("print", "no matches for '" .. rest .. "'")
  end
  local lines = {}
  for _, hit in ipairs(hits) do
    local snippet = (hit.doc or ""):match("^[^\n]+") or ""
    if #snippet > 80 then
      snippet = snippet:sub(1, 77) .. "..."
    end
    lines[#lines + 1] = string.format("%-32s [%s]  %s", hit.key, hit.kind, snippet)
  end
  return records.new_command_action("print", table.concat(lines, "\n"))
end

local function cmd_find_source(rest)
  rest = prelude.trim(rest or "")
  if rest == "" then
    return records.new_command_action("print", "usage: /find-source <symbol>")
  end
  local doc = require("psi.doc")
  local key = resolve_doc_key(rest)
  if not key then
    return records.new_command_action("print", "no entry for '" .. rest .. "'")
  end
  local entry = doc.get(key)
  return records.new_command_action(
    "print",
    string.format("%s -> %s", key, entry.source or "(unknown)")
  )
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
    argument_hint = "[path]",
    description = "Open the session picker or load a session file from disk",
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
    name = "theme",
    argument_hint = "[name]",
    description = "List or switch the color theme",
  },
  {
    name = "login",
    argument_hint = "[method|provider]",
    description = "Configure provider authentication",
  },
  {
    name = "logout",
    argument_hint = "[provider]",
    description = "Remove a stored provider credential",
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
    name = "tree",
    argument_hint = "[entry-id] [--summarize] [focus]",
    description = "Navigate the session tree and optionally summarize the branch you leave",
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
    name = "trust",
    argument_hint = "[always|never]",
    description = "Show or save this directory's .psi resource trust decision",
  },
  {
    name = "rainbow",
    description = "Show all 256 terminal background colors",
  },
  {
    name = "queue",
    argument_hint = "[subcommand]",
    description = "Inspect, edit, enqueue, or configure queued messages",
  },
  {
    name = "system-prompt",
    description = "Print the current coding-agent system prompt",
  },
  {
    name = "describe",
    argument_hint = "<symbol>",
    description = "Show the docstring for a slash command, tool, primitive, key, or provider",
  },
  {
    name = "apropos",
    argument_hint = "<pattern>",
    description = "Search docstrings for a substring",
  },
  {
    name = "find-source",
    argument_hint = "<symbol>",
    description = "Print the file path that defines a documented symbol",
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

local function completion_scan_dir(dir)
  if dir == "" then
    return "."
  end
  if dir:sub(1, 2) == "~/" then
    local home = os.getenv("HOME") or os.getenv("USERPROFILE")
    if home and home ~= "" then
      return home .. dir:sub(2)
    end
  end
  return dir
end

local function completion_is_dir(path)
  return psi.list_dir ~= nil and psi.list_dir(path) ~= nil
end

local function path_completions(token, limit)
  if type(token) ~= "string" or not psi.list_dir then
    return nil
  end
  local slash = token:match("^.*()/")
  local dir, base
  if slash then
    dir = token:sub(1, slash)
    base = token:sub(slash + 1)
  else
    dir = ""
    base = token
  end
  local scan = completion_scan_dir(dir)
  local entries = psi.list_dir(scan)
  if type(entries) ~= "table" then
    return nil
  end
  table.sort(entries)
  local allow_hidden = base:sub(1, 1) == "."
  local scan_prefix = scan:sub(-1) == "/" and scan or (scan .. "/")
  local out = {}
  for _, name in ipairs(entries) do
    if #out >= (limit or 20) then
      break
    end
    local matches = base == "" or name:sub(1, #base) == base
    local visible = allow_hidden or name:sub(1, 1) ~= "."
    if matches and visible then
      local is_dir = completion_is_dir(scan_prefix .. name)
      out[#out + 1] = {
        insert = dir .. name .. (is_dir and "/" or ""),
        label = name .. (is_dir and "/" or ""),
        trailing = "",
      }
    end
  end
  return out
end

local function model_arg_completions(arg, limit)
  local ok, registry = pcall(require, "psi.api_registry")
  if not ok or type(registry) ~= "table" or not registry.all_models then
    return nil
  end
  local ok_models, models = pcall(registry.all_models)
  if not ok_models or type(models) ~= "table" then
    return nil
  end
  local out = {}
  for _, m in ipairs(models) do
    if #out >= (limit or 40) then
      break
    end
    local id = m.id
    if type(id) == "string" and (arg == "" or id:find(arg, 1, true) ~= nil) then
      out[#out + 1] = { insert = id, label = id, description = m.name, trailing = "" }
    end
  end
  return out
end

local function theme_arg_completions(arg, limit)
  local names = {}
  if psi.theme and psi.theme.names then
    local ok, list = pcall(psi.theme.names)
    if ok and type(list) == "table" then
      names = list
    end
  end
  local out = {}
  for _, n in ipairs(names) do
    if #out >= (limit or 40) then
      break
    end
    if type(n) == "string" and (arg == "" or n:find(arg, 1, true) ~= nil) then
      out[#out + 1] = { insert = n, label = n, trailing = "" }
    end
  end
  return out
end

local function static_arg_completions(values)
  return function(arg, limit)
    local out = {}
    for _, v in ipairs(values) do
      if #out >= (limit or 40) then
        break
      end
      if arg == "" or v:sub(1, #arg) == arg then
        out[#out + 1] = { insert = v, label = v, trailing = "" }
      end
    end
    return out
  end
end

local function login_arg_completions(arg, limit)
  local prefix, token = arg:match("^(.-%s)(%S*)$")
  if not prefix then
    token = arg
  end
  local first = split_first_word(prefix or "")
  local auth_type = AUTH_METHOD_ALIASES[tostring(first):lower()]
  local out = {}
  local seen = {}
  local function append(insert, label, description, trailing)
    if #out >= (limit or 40) or seen[insert] or not prelude.starts_with(insert, token) then
      return
    end
    seen[insert] = true
    out[#out + 1] = {
      insert = insert,
      label = label or insert,
      description = description,
      trailing = trailing or "",
    }
  end

  if prefix then
    if not auth_type or prefix:match("%S+%s+%S+%s") then
      return nil, token
    end
    for _, option in ipairs(provider_auth_options(auth_type)) do
      append(option.provider, option.provider, option.name, " ")
    end
    return out, token
  end

  for _, method in ipairs(AUTH_METHODS) do
    append(method.id, method.id, method.description, " ")
  end
  local descriptions = {}
  for _, option in ipairs(provider_auth_options()) do
    local description = auth_method_label(option.auth_type) .. " — " .. option.name
    if descriptions[option.provider] then
      descriptions[option.provider] = descriptions[option.provider] .. ", " .. description
    else
      descriptions[option.provider] = description
    end
  end
  for provider, description in pairs(descriptions) do
    append(provider, provider, description, " ")
  end
  table.sort(out, function(a, b)
    return a.insert < b.insert
  end)
  return out, token
end

local function logout_arg_completions(arg, limit)
  local auth_storage = require("psi.auth_storage")
  local stored = auth_storage.list()
  if type(stored) ~= "table" then
    return nil
  end
  local out = {}
  for _, item in ipairs(stored) do
    if #out >= (limit or 40) then
      break
    end
    if arg == "" or prelude.starts_with(item.provider, arg) then
      out[#out + 1] = {
        insert = item.provider,
        label = item.provider,
        description = auth_method_label(item.type) .. " — " .. provider_display_name(
          item.provider
        ),
        trailing = "",
      }
    end
  end
  return out
end

local PATH_ARG_COMMANDS = {
  resume = true,
  import = true,
  export = true,
  clone = true,
}

local ENUM_ARG_COMPLETERS = {
  model = model_arg_completions,
  theme = theme_arg_completions,
  thinking = static_arg_completions({ "off", "minimal", "low", "medium", "high", "xhigh" }),
  login = login_arg_completions,
  logout = logout_arg_completions,
}

function M.input_completions(input, cursor, limit, force)
  if type(input) ~= "string" then
    return nil
  end
  cursor = tonumber(cursor) or #input
  if cursor < 0 then
    cursor = 0
  elseif cursor > #input then
    cursor = #input
  end
  local before = input:sub(1, cursor)
  limit = tonumber(limit) or 24

  if before:match("^/[%w%-_]*$") then
    local cmds = M.command_suggestions(before, limit)
    if type(cmds) ~= "table" or #cmds == 0 then
      return nil
    end
    local items = {}
    for _, c in ipairs(cmds) do
      local label = "/" .. c.name
      if c.argument_hint and c.argument_hint ~= "" then
        label = label .. " " .. c.argument_hint
      end
      local desc = c.description
      if c.alias_of and c.alias_of ~= c.name then
        local base = (desc and desc ~= "") and (" - " .. desc) or ""
        desc = "alias for /" .. c.alias_of .. base
      end
      items[#items + 1] = {
        insert = "/" .. c.name,
        label = label,
        description = desc,
        trailing = (c.argument_hint and c.argument_hint ~= "") and " " or "",
      }
    end
    return { start = 1, kind = "command", prefix = before, items = items }
  end

  local cmd_name, sep = before:match("^/(%S+)(%s+)")
  if cmd_name then
    local arg = before:sub(#("/" .. cmd_name .. sep) + 1)
    if PATH_ARG_COMMANDS[cmd_name] then
      local token = arg:match("(%S*)$") or ""
      local items = path_completions(token, limit)
      if type(items) ~= "table" or #items == 0 then
        return nil
      end
      return {
        start = cursor - #token + 1,
        kind = "argument",
        prefix = token,
        items = items,
      }
    end
    local completer = ENUM_ARG_COMPLETERS[cmd_name]
    if not completer or (cmd_name ~= "login" and arg:find("%s")) then
      return nil
    end
    local items, replacement = completer(arg, limit)
    if type(items) ~= "table" or #items == 0 then
      return nil
    end
    replacement = replacement or arg
    return {
      start = cursor - #replacement + 1,
      kind = "argument",
      prefix = replacement,
      items = items,
    }
  end

  local token = before:match("(%S*)$") or ""
  local path_like = token:find("/", 1, true) ~= nil
    or token:sub(1, 1) == "."
    or token:sub(1, 2) == "~/"
  if token == "" or (not force and not path_like) then
    return nil
  end
  local items = path_completions(token, limit)
  if type(items) ~= "table" or #items == 0 then
    return nil
  end
  return {
    start = cursor - #token + 1,
    kind = "path",
    prefix = token,
    items = items,
  }
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
    notice.error(
      "psi.commands: /" .. first .. " failed: " .. tostring(result),
      { source = "slash-command" }
    )
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
  if starts_word(line, "/trust") then
    return cmd_trust(arg_after(line, "/trust"))
  end
  if line == "/rainbow" then
    return cmd_rainbow()
  end
  if starts_word(line, "/queue") then
    return cmd_queue(arg_after(line, "/queue"))
  end
  if starts_word(line, "/describe") then
    return cmd_describe(arg_after(line, "/describe"))
  end
  if starts_word(line, "/apropos") then
    return cmd_apropos(arg_after(line, "/apropos"))
  end
  if starts_word(line, "/find-source") then
    return cmd_find_source(arg_after(line, "/find-source"))
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
  if starts_word(line, "/theme") then
    return cmd_theme(arg_after(line, "/theme"))
  end
  if starts_word(line, "/login") then
    return cmd_login(arg_after(line, "/login"))
  end
  if starts_word(line, "/logout") then
    return cmd_logout(arg_after(line, "/logout"))
  end
  if starts_word(line, "/resume") then
    local path = arg_after(line, "/resume")
    if path == "" then
      return records.new_command_action("resume-picker", nil)
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
    local ok, err = session.fork(keep, out)
    local msg = ok and ("forked " .. tostring(keep) .. " entries to " .. out)
      or ("fork failed: " .. tostring(err or "could not determine session path"))
    return records.new_command_action("print", msg)
  end
  if starts_word(line, "/clone") then
    local rest = arg_after(line, "/clone")
    local out = (rest ~= "" and rest) or clone_output_path()
    local total = psi.session_message_count()
    local ok, err = session.fork(total, out)
    local msg = ok and string.format("cloned %d entries to %s", total, out)
      or ("clone failed: " .. tostring(err or "could not determine session path"))
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
  if starts_word(line, "/tree") then
    local rest = arg_after(line, "/tree")
    if rest == "" then
      return records.new_command_action("print", session.branch_tree_text())
    end
    local payload = parse_tree_args(rest)
    if not payload or payload.target == "" then
      return records.new_command_action("print", "usage: /tree <entry-id> [--summarize] [focus]")
    end
    return records.new_command_action("tree", payload)
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
