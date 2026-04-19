-- psi.session: session accessors and compaction algorithm.
--
-- Storage lives in C; this layer provides the pure algorithm and a
-- message-record view. The C FFI exposes:
--   psi.session_message_count()
--   psi.session_messages()            -- array of {role, text, data}
--   psi.session_append(role, text, data_or_nil)
--   psi.session_clear()

local records = require("psi.records")
local prelude = require("psi.prelude")

local M = {}

function M.count() return psi.session_message_count() end

function M.messages() return records.messages_from_alists(psi.session_messages()) end

function M.append_message(msg)
  psi.session_append(msg.role, msg.text, msg.data)
end

-- Replace session with [summary] + last keep_recent messages.
function M.do_compact(keep_recent, summary_text)
  local messages = M.messages()
  local total = #messages
  if keep_recent > total then keep_recent = total end
  local tail = prelude.drop(messages, total - keep_recent)
  psi.session_clear()
  M.append_message(records.new_message("compaction-summary", summary_text, nil))
  for _, m in ipairs(tail) do M.append_message(m) end
  return true
end

function M.role_prefix(message)
  local role = message.role
  if role == "user" then return "User: " end
  if role == "assistant" then return "Assistant: " end
  if role == "tool-call" then return "Tool call: " end
  if role == "tool-result" then return "Tool result: " end
  if role == "compaction-summary" then return "Previous summary: " end
  if role == "branch-summary" then return "Branch summary: " end
  return "Message: "
end

return M
