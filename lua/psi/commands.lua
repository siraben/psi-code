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
  return nil
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
