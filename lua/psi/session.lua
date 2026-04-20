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

-- ---------- id generation ----------

local id_counter = 0
local function generate_id(prefix)
  id_counter = id_counter + 1
  return (prefix or "") .. tostring(os.time()) .. "-" .. tostring(id_counter)
end

-- ---------- JSONL persistence ----------

local function ensure_parent_dir(path)
  local slash = path:match("()/[^/]*$")  -- index of the last slash
  if not slash or slash <= 1 then return end
  local dir = path:sub(1, slash - 1)
  os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")
end

local function write_line(file, obj)
  file:write(psi.json_encode(obj))
  file:write("\n")
end

local function session_header()
  local hdr = {
    type = "session",
    version = 1,
    id = psi.session_id() or "",
  }
  local parent = psi.session_parent_id()
  if parent and parent ~= "" then hdr.parent = parent end
  return hdr
end

local function message_entry(m)
  local entry = {type = "message", role = m.role or "custom", text = m.text or ""}
  if m.data then entry.data = m.data end
  return entry
end

-- Write `header` followed by the first `count` messages (nil = all) to `path`.
local function write_session_file(path, header, messages, count)
  ensure_parent_dir(path)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  write_line(f, header)
  local n = count or #messages
  for i = 1, n do
    write_line(f, message_entry(messages[i]))
  end
  f:close()
  return true
end

function M.save(path)
  if not path or path == "" then
    path = psi.session_path()
  end
  if not path or path == "" then
    -- No session file was ever associated; quietly skip (mirrors the
    -- previous C behavior of returning success on NULL path).
    return true
  end
  if not psi.session_id() or psi.session_id() == "" then
    psi.session_set_id(generate_id(""))
  end
  return write_session_file(path, session_header(), psi.session_messages())
end

function M.load(path)
  if not path or path == "" then return false, "no path" end
  psi.session_set_path(path)

  local f = io.open(path, "r")
  if not f then
    -- missing file: caller can still save later; just ensure an id.
    if not psi.session_id() or psi.session_id() == "" then
      psi.session_set_id(generate_id(""))
    end
    return true
  end

  psi.session_clear()
  for line in f:lines() do
    local parsed = prelude.safe_json_decode(line)
    if type(parsed) == "table" then
      if parsed.type == "session" then
        if parsed.id then psi.session_set_id(parsed.id) end
        if parsed.parent then psi.session_set_parent_id(parsed.parent) end
      elseif parsed.type == "message" and parsed.text then
        psi.session_append(parsed.role or "custom", parsed.text, parsed.data)
      end
    end
  end
  f:close()

  if not psi.session_id() or psi.session_id() == "" then
    psi.session_set_id(generate_id(""))
  end
  return true
end

-- Write the first `at_count` messages of the current session to a new
-- JSONL file at `out_path`, stamped with a fresh id whose parent is
-- the current session's id. Current session is not modified.
function M.fork(at_count, out_path)
  if not out_path or out_path == "" then return false, "no path" end
  local messages = psi.session_messages()
  if at_count > #messages then at_count = #messages end
  if at_count < 0 then at_count = 0 end
  local header = {
    type = "session",
    version = 1,
    id = generate_id("fork-"),
    parent = psi.session_id(),
  }
  return write_session_file(out_path, header, messages, at_count)
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
