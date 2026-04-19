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

-- ---------- file-op tracking for compaction provenance ----------
--
-- An after-hook accumulates read/modified paths as tools fire. When a
-- compaction runs, the pending ops get embedded into the
-- compaction-summary entry's data payload so a future session-replay
-- knows which files the compacted range touched, even though the
-- individual messages are gone.

local pending_read = {}
local pending_modified = {}

local function record_file_op(name, input, result)
  if not (result and result.ok) then return end
  if not (input and type(input.path) == "string") then return end
  if name == "read" then
    pending_read[input.path] = true
  elseif name == "write" or name == "edit" then
    pending_modified[input.path] = true
  end
end

local function keys_of(t)
  local out = {}
  for k, _ in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function M.pending_file_ops()
  return keys_of(pending_read), keys_of(pending_modified)
end

function M.reset_file_ops()
  pending_read = {}
  pending_modified = {}
end

-- Registered once at module load; tools.lua's registry fires this for
-- every tool call (including rejected ones — record_file_op guards).
require("psi.tool_registry").add_after_hook(record_file_op)

-- Replace session with [summary] + last keep_recent messages. The
-- compaction-summary entry carries structured provenance in its data
-- field: {readFiles, modifiedFiles, compactedCount}.
function M.do_compact(keep_recent, summary_text)
  local messages = M.messages()
  local total = #messages
  if keep_recent > total then keep_recent = total end
  local compacted_count = total - keep_recent
  local tail = prelude.drop(messages, compacted_count)

  local read_files, modified_files = M.pending_file_ops()
  local data_payload = psi.json_encode(setmetatable({
    readFiles = prelude.as_array(read_files),
    modifiedFiles = prelude.as_array(modified_files),
    compactedCount = compacted_count,
  }, nil))

  psi.session_clear()
  M.append_message(records.new_message("compaction-summary", summary_text, data_payload))
  for _, m in ipairs(tail) do M.append_message(m) end
  M.reset_file_ops()
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
