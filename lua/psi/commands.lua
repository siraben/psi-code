-- psi.commands: slash-command dispatch.

local records = require("psi.records")
local prelude = require("psi.prelude")
local prompt = require("psi.prompt")

local M = {}

local COMPACT_DEFAULT = 12

local function parse_compact_count(line)
  local rest = prelude.trim(line:sub(9))
  if #rest == 0 then
    return COMPACT_DEFAULT
  end
  return tonumber(rest) or COMPACT_DEFAULT
end

local function is_compact_command(line)
  if not prelude.starts_with(line, "/compact") then
    return false
  end
  if #line == 8 then
    return true
  end
  local ch = line:sub(9, 9)
  return ch == " " or ch == "\t"
end

local function is_fork_command(line)
  if not prelude.starts_with(line, "/fork") then
    return false
  end
  if #line == 5 then
    return true
  end
  local ch = line:sub(6, 6)
  return ch == " " or ch == "\t"
end

local function parse_fork_count(line)
  local rest = prelude.trim(line:sub(6))
  if #rest == 0 then
    return psi.session_message_count()
  end
  return tonumber(rest) or psi.session_message_count()
end

local function fork_output_path()
  local id = psi.session_id() or tostring(os.time())
  return "sessions/fork-" .. id .. "-" .. tostring(os.time()) .. ".jsonl"
end

local function session_status()
  return "session-messages: " .. tostring(psi.session_message_count())
end

-- Extension-registered commands. Keyed by the first whitespace-
-- delimited token after the leading slash (e.g. "/hello" registers
-- under "hello"). Handlers receive (args_string, raw_line) and must
-- return a records.command_action (via records.new_command_action)
-- or nil. Registering an existing name overwrites the handler.
local registered = {}

function M.register(name, handler)
  if type(name) ~= "string" or type(handler) ~= "function" then return end
  local key = name:gsub("^/", "")
  registered[key] = handler
end

function M.unregister(name)
  if type(name) ~= "string" then return end
  registered[name:gsub("^/", "")] = nil
end

local function dispatch_registered(line)
  if line:sub(1, 1) ~= "/" then return nil end
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

function M.handle(line)
  if line == "/help" or line == "/h" then
    return records.new_command_action("print", prompt.help_text())
  end
  if line == "/session" then
    return records.new_command_action("print", session_status())
  end
  if line == "/system-prompt" then
    return records.new_command_action("print", prompt.system_prompt())
  end
  if is_compact_command(line) then
    return records.new_command_action("compact", parse_compact_count(line))
  end
  if is_fork_command(line) then
    local keep = parse_fork_count(line)
    local out = fork_output_path()
    local ok = psi.session_fork(keep, out)
    local msg = ok and ("forked " .. tostring(keep) .. " entries to " .. out) or "fork failed"
    return records.new_command_action("print", msg)
  end
  return dispatch_registered(line)
end

-- Bridge for C: returns either nil or a {kind-string, payload} sequence.
function M.handle_command_list(line)
  local action = M.handle(line)
  if not action then
    return nil
  end
  return records.command_action_to_list(action)
end

return M
