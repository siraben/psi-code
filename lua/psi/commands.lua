-- psi.commands: slash-command dispatch.
--
-- Built-in commands return a records.command_action via one of two
-- channels:
--   * self-contained (kind="print") — rendered directly
--   * action-kinds that the REPL dispatcher in modes.lua knows how to
--     handle (set-model, new-session, resume, reload, export, name,
--     quit). TUI mode currently understands only "print" and "compact";
--     new actions are REPL-only.
--
-- Extension-registered commands (psi.commands.register(name, handler))
-- are consulted last, after built-ins.

local records = require("psi.records")
local prelude = require("psi.prelude")
local prompt = require("psi.prompt")
local session = require("psi.session")

local M = {}

local COMPACT_DEFAULT = 12

-- ---------- parsers ----------

local function arg_after(line, prefix)
  return prelude.trim(line:sub(#prefix + 1))
end

local function starts_word(line, word)
  if not prelude.starts_with(line, word) then return false end
  if #line == #word then return true end
  local ch = line:sub(#word + 1, #word + 1)
  return ch == " " or ch == "\t"
end

local function parse_compact_count(line)
  local rest = arg_after(line, "/compact")
  if #rest == 0 then return COMPACT_DEFAULT end
  return tonumber(rest) or COMPACT_DEFAULT
end

local function parse_fork_count(line)
  local rest = arg_after(line, "/fork")
  if #rest == 0 then return psi.session_message_count() end
  return tonumber(rest) or psi.session_message_count()
end

local function fork_output_path()
  local id = psi.session_id() or tostring(os.time())
  return "sessions/fork-" .. id .. "-" .. tostring(os.time()) .. ".jsonl"
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
  if name and name ~= "" then lines[#lines + 1] = "name:      " .. name end
  lines[#lines + 1] = "id:        " .. tostring(psi.session_id() or "-")
  local path = psi.session_path() or ""
  if path ~= "" then lines[#lines + 1] = "file:      " .. path end
  lines[#lines + 1] = "messages:  " .. tostring(psi.session_message_count())
  local last = last_assistant_summary()
  if last then
    lines[#lines + 1] = "provider:  " .. tostring(last.provider or "-")
    lines[#lines + 1] = "model:     " .. tostring(last.model or "-")
    if last.usage then
      lines[#lines + 1] = string.format(
        "usage:     in=%d out=%d cacheRead=%d cacheWrite=%d total=%d",
        last.usage.input or 0, last.usage.output or 0,
        last.usage.cacheRead or 0, last.usage.cacheWrite or 0,
        last.usage.totalTokens or 0)
    end
  end
  return table.concat(lines, "\n")
end

-- ---------- clipboard (/copy) ----------

local CLIPBOARD_CMDS = {
  "xclip -selection clipboard",
  "pbcopy",
  "wl-copy",
  "xsel --clipboard --input",
}

local function last_assistant_text()
  local last = last_assistant_summary()
  if not last then return nil end
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

local function copy_to_clipboard(text)
  for _, cmd in ipairs(CLIPBOARD_CMDS) do
    local handle = io.popen(cmd .. " 2>/dev/null", "w")
    if handle then
      local ok_write = pcall(function() handle:write(text); handle:flush() end)
      local ok_close, _, rc = handle:close()
      if ok_write and ok_close and (rc == nil or rc == 0) then
        return true, cmd:match("^(%S+)")
      end
    end
  end
  return false
end

local function cmd_copy()
  local text = last_assistant_text()
  if not text or text == "" then
    return records.new_command_action("print", "no assistant message to copy")
  end
  local ok, tool = copy_to_clipboard(text)
  if ok then
    return records.new_command_action("print",
      string.format("copied %d chars via %s", #text, tool))
  end
  return records.new_command_action("print",
    "clipboard unavailable (tried xclip, pbcopy, wl-copy, xsel)")
end

-- ---------- markdown export (/export) ----------

local function render_markdown_session()
  local lines = {}
  local add = function(s) lines[#lines + 1] = s end
  add("# Session " .. tostring(psi.session_id() or "-"))
  local path = psi.session_path() or ""
  if path ~= "" then add("- **file**: " .. path) end
  add("- **generated**: " .. prelude.iso_timestamp())
  add("")
  for _, m in ipairs(psi.session_messages()) do
    local body = prelude.safe_json_decode(m.data, nil)
    local msg = type(body) == "table" and body.message or nil
    if m.role == "user" and msg then
      add("## User"); add("")
      add(m.text or ""); add("")
    elseif m.role == "assistant" and msg then
      local model = msg.model or "?"
      local u = msg.usage or {}
      local stop = msg.stopReason or "-"
      add(string.format("## Assistant — %s (stop=%s, in=%d out=%d)",
        model, stop, u.input or 0, u.output or 0))
      add("")
      for _, b in ipairs(msg.content or {}) do
        if type(b) == "table" then
          if b.type == "text" then
            add(b.text or ""); add("")
          elseif b.type == "toolCall" then
            add(string.format("### Tool call: `%s` (id=%s)", b.name or "?", b.id or "?"))
            add("```json")
            add(psi.json_encode(b.arguments or {}))
            add("```"); add("")
          end
        end
      end
    elseif m.role == "tool-result" and msg then
      add(string.format("### Tool result: `%s` (id=%s%s)",
        msg.toolName or "?", msg.toolCallId or "?",
        msg.isError and ", error" or ""))
      add("```")
      add(m.text or "")
      add("```"); add("")
    elseif m.role == "compaction-summary" then
      add("## Compaction summary"); add("")
      add(m.text or ""); add("")
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
  local ok = psi.file_write(path, content)
  if ok then
    return records.new_command_action("print",
      string.format("exported %d chars to %s", #content, path))
  end
  return records.new_command_action("print", "export failed: " .. path)
end

-- ---------- dispatcher + registry ----------

local registered = {}

function M.register(name, handler)
  if type(name) ~= "string" or type(handler) ~= "function" then return end
  registered[name:gsub("^/", "")] = handler
end

function M.unregister(name)
  if type(name) ~= "string" then return end
  registered[name:gsub("^/", "")] = nil
end

local function dispatch_registered(line)
  local first, rest = line:match("^/(%S+)%s*(.*)$")
  if not first then return nil end
  local handler = registered[first]
  if not handler then return nil end
  local ok, result = pcall(handler, rest or "", line)
  if not ok then
    io.stderr:write("psi.commands: /" .. first .. " failed: "
      .. tostring(result) .. "\n")
    return records.new_command_action("print", "command /" .. first .. " failed")
  end
  return result
end

local function is_quit(line)
  return line == "/quit" or line == "/q" or line == ":quit" or line == ":q"
end

function M.handle(line)
  if line == "/help" or line == "/h" then
    return records.new_command_action("print", prompt.help_text())
  end
  if is_quit(line) then
    return records.new_command_action("quit", nil)
  end
  if line == "/session" then
    return records.new_command_action("print", session_status())
  end
  if line == "/system-prompt" then
    return records.new_command_action("print", prompt.system_prompt())
  end
  if line == "/copy" then
    return cmd_copy()
  end
  if line == "/new" then
    return records.new_command_action("new-session", nil)
  end
  if line == "/reload" then
    return records.new_command_action("reload", nil)
  end
  if starts_word(line, "/model") then
    local spec = arg_after(line, "/model")
    if spec == "" then
      return records.new_command_action("print", "usage: /model <spec> (e.g. ollama/llama3.1:latest)")
    end
    return records.new_command_action("set-model", spec)
  end
  if starts_word(line, "/resume") then
    local path = arg_after(line, "/resume")
    if path == "" then
      return records.new_command_action("print", "usage: /resume <path>")
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
  return dispatch_registered(line)
end

-- Bridge for C (TUI): returns nil or a {kind-string, payload} sequence.
function M.handle_command_list(line)
  local action = M.handle(line)
  if not action then return nil end
  return records.command_action_to_list(action)
end

return M
