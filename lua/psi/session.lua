-- psi.session: session accessors, append wrappers, and compaction.
--
-- Disk format is the v2 pi-style schema (ported from pi-mono). In memory
-- we still use psi's minimal (role, text, data) triple exposed by the C
-- FFI; `data` is a JSON string encoding the v2 entry body minus `type`.
-- Example `data` decoded for an assistant message:
--
--   { id = "...", parentId = "...", timestamp = "...",
--     message = { role = "assistant", content = {...}, usage = {...},
--                 stopReason = "...", model = "..." } }
--
-- For compaction entries the `data` holds
--   { id, parentId, timestamp, summary, firstKeptEntryId?,
--     tokensBefore?, readFiles?, modifiedFiles?, compactedCount? }
-- with in-memory role "compaction-summary".
--
-- The C FFI exposes:
--   psi.session_message_count()
--   psi.session_messages()            -- array of {role, text, data}
--   psi.session_append(role, text, data_or_nil)
--   psi.session_clear()

local records = require("psi.records")
local prelude = require("psi.prelude")

local M = {}

local SESSION_VERSION = 2

-- ---------- Entry metadata (id/parent threading) ----------

-- The in-memory entry chain is strictly linear, so we only need the id
-- of the most recently appended entry as the parent for the next one.
local last_entry_id = nil

function M.reset_entry_chain() last_entry_id = nil end
function M.last_entry_id() return last_entry_id end

local function stamp_entry(body)
  body = body or {}
  body.id = body.id or prelude.uuid_short()
  body.timestamp = body.timestamp or prelude.iso_timestamp()
  if body.parentId == nil then body.parentId = last_entry_id end
  last_entry_id = body.id
  return body
end

function M.count() return psi.session_message_count() end

function M.messages() return records.messages_from_alists(psi.session_messages()) end

-- Internal: append an in-memory message record verbatim (used when
-- reconstructing state during compaction). Does not re-stamp metadata.
function M.append_message(msg)
  psi.session_append(msg.role, msg.text, msg.data)
end

-- ---------- Append wrappers (pi-shape content builders) ----------

local function text_block(s) return {type = "text", text = s or ""} end

-- pi normalizes Anthropic's verbose usage keys.
local function normalize_usage(u)
  if type(u) ~= "table" then return nil end
  local input  = u.input_tokens              or u.input  or 0
  local output = u.output_tokens             or u.output or 0
  local cr     = u.cache_read_input_tokens     or u.cacheRead  or 0
  local cw     = u.cache_creation_input_tokens or u.cacheWrite or 0
  return {
    input = input, output = output,
    cacheRead = cr, cacheWrite = cw,
    totalTokens = input + output + cr + cw,
  }
end

-- pi uses camelCase stop reasons. Anthropic emits snake_case over the wire.
local STOP_REASON_CAMEL = {
  end_turn = "endTurn", tool_use = "toolUse",
  stop_sequence = "stopSequence", max_tokens = "maxTokens",
  pause_turn = "pauseTurn", refusal = "refusal",
}
local function normalize_stop_reason(r)
  if type(r) ~= "string" then return nil end
  return STOP_REASON_CAMEL[r] or r
end

local function unix_ms() return math.floor(os.time() * 1000) end

local function pi_content_from_blocks(blocks)
  local out = prelude.as_array({})
  for _, b in ipairs(blocks or {}) do
    if b.type == "text" then
      out[#out + 1] = {type = "text", text = b.text or ""}
    elseif b.type == "tool_use" then
      out[#out + 1] = {type = "toolCall", id = b.id, name = b.name,
                        arguments = b.input or {}}
    elseif b.type == "thinking" then
      out[#out + 1] = {type = "thinking", thinking = b.thinking or ""}
    end
  end
  return out
end

function M.append_user(text)
  local body = stamp_entry({
    message = {role = "user", content = prelude.as_array({text_block(text)}),
               timestamp = unix_ms()},
  })
  psi.session_append("user", text or "", psi.json_encode(body))
end

-- blocks: Anthropic-shape array (type=text|tool_use|thinking).
-- opts: {usage?, stop_reason?, model?, provider?, response_id?, api?}
function M.append_assistant(text, blocks, opts)
  opts = opts or {}
  local msg = {role = "assistant", content = pi_content_from_blocks(blocks)}
  msg.timestamp = unix_ms()
  local usage = normalize_usage(opts.usage)
  if usage            then msg.usage       = usage                              end
  local stop = normalize_stop_reason(opts.stop_reason)
  if stop             then msg.stopReason  = stop                               end
  if opts.model       then msg.model       = opts.model                         end
  if opts.provider    then msg.provider    = opts.provider                      end
  if opts.api         then msg.api         = opts.api                           end
  if opts.response_id then msg.responseId  = opts.response_id                   end
  local body = stamp_entry({message = msg})
  psi.session_append("assistant", text or "", psi.json_encode(body))
end

function M.append_tool_result(tool_use_id, tool_name, content_text, is_error)
  local msg = {
    role = "toolResult",
    toolCallId = tool_use_id,
    toolName = tool_name,
    content = prelude.as_array({text_block(content_text)}),
    timestamp = unix_ms(),
  }
  if is_error then msg.isError = true end
  local body = stamp_entry({message = msg})
  psi.session_append("tool-result", content_text or "", psi.json_encode(body))
end

function M.append_compaction(summary_text, extra)
  local body = {summary = summary_text or ""}
  if extra then
    for k, v in pairs(extra) do body[k] = v end
  end
  body = stamp_entry(body)
  psi.session_append("compaction-summary", summary_text or "", psi.json_encode(body))
end

-- ---------- JSONL persistence ----------

local function ensure_parent_dir(path)
  local slash = path:match("()/[^/]*$")
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
    version = SESSION_VERSION,
    id = psi.session_id() or "",
    timestamp = prelude.iso_timestamp(),
    cwd = os.getenv("PWD") or ".",
  }
  local parent = psi.session_parent_id()
  if parent and parent ~= "" then hdr.parent = parent end
  return hdr
end

-- Convert an in-memory (role, text, data) record into a v2 disk entry.
local function to_disk_entry(m)
  local body = prelude.safe_json_decode(m.data, nil)
  if type(body) ~= "table" then
    -- Legacy/synthetic record with no structured body: build a minimal one.
    body = stamp_entry({
      message = {role = m.role or "user",
                 content = prelude.as_array({text_block(m.text)})},
    })
  end
  if m.role == "compaction-summary" then
    local out = {type = "compaction"}
    for _, k in ipairs({"id", "parentId", "timestamp", "summary",
                         "firstKeptEntryId", "tokensBefore",
                         "readFiles", "modifiedFiles", "compactedCount"}) do
      if body[k] ~= nil then out[k] = body[k] end
    end
    if out.summary == nil then out.summary = m.text or "" end
    return out
  end
  local out = {type = "message"}
  for _, k in ipairs({"id", "parentId", "timestamp", "message"}) do
    if body[k] ~= nil then out[k] = body[k] end
  end
  return out
end

local function write_session_file(path, header, messages, count)
  ensure_parent_dir(path)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  write_line(f, header)
  local n = count or #messages
  for i = 1, n do
    write_line(f, to_disk_entry(messages[i]))
  end
  f:close()
  return true
end

function M.save(path)
  if not path or path == "" then path = psi.session_path() end
  if not path or path == "" then return true end
  if not psi.session_id() or psi.session_id() == "" then
    psi.session_set_id(prelude.uuid_short())
  end
  return write_session_file(path, session_header(), psi.session_messages())
end

-- ---------- Loader: v2 native + v1 upconvert ----------

-- v1 assistant.data was a JSON string of Anthropic content blocks
-- (type=text|tool_use). Map it into the v2 `message.content` shape.
local function v1_assistant_data_to_v2(raw, text)
  local blocks = prelude.safe_json_decode(raw, nil)
  if type(blocks) ~= "table" then
    return {role = "assistant", content = prelude.as_array({text_block(text)})}
  end
  return {role = "assistant", content = pi_content_from_blocks(blocks)}
end

-- v1 tool-result `text` field held a JSON blob:
-- {tool_use_id, tool, content, is_error}. Lift into v2 toolResult.
local function v1_tool_result_text_to_v2(text)
  local parsed = prelude.safe_json_decode(text, nil)
  if type(parsed) ~= "table" then
    return {role = "toolResult", toolCallId = "", toolName = "",
             content = prelude.as_array({text_block(text)})}
  end
  local msg = {
    role = "toolResult",
    toolCallId = parsed.tool_use_id or "",
    toolName   = parsed.tool or "",
    content    = prelude.as_array({text_block(parsed.content or "")}),
  }
  if parsed.is_error then msg.isError = true end
  return msg
end

local function append_v1_entry(parsed)
  local role = parsed.role or "custom"
  local text = parsed.text or ""
  if role == "user" then
    M.append_user(text)
  elseif role == "assistant" then
    local msg = v1_assistant_data_to_v2(parsed.data, text)
    local body = stamp_entry({message = msg})
    psi.session_append("assistant", text, psi.json_encode(body))
  elseif role == "tool-result" then
    local msg = v1_tool_result_text_to_v2(text)
    local body = stamp_entry({message = msg})
    psi.session_append("tool-result", text, psi.json_encode(body))
  elseif role == "compaction-summary" then
    -- v1 data held provenance JSON; preserve under v2 keys.
    local extra = prelude.safe_json_decode(parsed.data, nil)
    if type(extra) ~= "table" then extra = {} end
    M.append_compaction(text, extra)
  else
    psi.session_append(role, text, parsed.data)
  end
end

local function append_v2_message(parsed)
  local msg = parsed.message
  if type(msg) ~= "table" then return end
  local body = {
    id = parsed.id,
    parentId = parsed.parentId,
    timestamp = parsed.timestamp,
    message = msg,
  }
  last_entry_id = body.id or last_entry_id
  local role = msg.role
  local text = ""
  if type(msg.content) == "table" then
    for _, b in ipairs(msg.content) do
      if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
        text = (text == "" and b.text) or (text .. b.text)
      end
    end
  end
  local in_mem_role = role
  if role == "toolResult" then in_mem_role = "tool-result" end
  psi.session_append(in_mem_role, text, psi.json_encode(body))
end

local function append_v2_compaction(parsed)
  local body = {}
  for _, k in ipairs({"id", "parentId", "timestamp", "summary",
                       "firstKeptEntryId", "tokensBefore",
                       "readFiles", "modifiedFiles", "compactedCount"}) do
    if parsed[k] ~= nil then body[k] = parsed[k] end
  end
  last_entry_id = body.id or last_entry_id
  psi.session_append("compaction-summary", body.summary or "",
                     psi.json_encode(body))
end

function M.load(path)
  if not path or path == "" then return false, "no path" end
  psi.session_set_path(path)

  local f = io.open(path, "r")
  if not f then
    if not psi.session_id() or psi.session_id() == "" then
      psi.session_set_id(prelude.uuid_short())
    end
    M.reset_entry_chain()
    return true
  end

  psi.session_clear()
  M.reset_entry_chain()

  local version = 1
  for line in f:lines() do
    local parsed = prelude.safe_json_decode(line)
    if type(parsed) == "table" then
      if parsed.type == "session" then
        version = parsed.version or 1
        if parsed.id then psi.session_set_id(parsed.id) end
        if parsed.parent then psi.session_set_parent_id(parsed.parent) end
      elseif parsed.type == "message" then
        if version >= 2 and parsed.message then
          append_v2_message(parsed)
        else
          append_v1_entry(parsed)
        end
      elseif parsed.type == "compaction" then
        append_v2_compaction(parsed)
      end
    end
  end
  f:close()

  if not psi.session_id() or psi.session_id() == "" then
    psi.session_set_id(prelude.uuid_short())
  end
  return true
end

-- Write the first `at_count` messages of the current session to a new
-- JSONL file at `out_path`, stamped with a fresh id whose parent is the
-- current session id. The current session is not modified.
function M.fork(at_count, out_path)
  if not out_path or out_path == "" then return false, "no path" end
  local messages = psi.session_messages()
  if at_count > #messages then at_count = #messages end
  if at_count < 0 then at_count = 0 end
  local header = {
    type = "session",
    version = SESSION_VERSION,
    id = prelude.uuid_short(),
    timestamp = prelude.iso_timestamp(),
    cwd = os.getenv("PWD") or ".",
    parent = psi.session_id(),
  }
  return write_session_file(out_path, header, messages, at_count)
end

-- ---------- file-op tracking for compaction provenance ----------

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

require("psi.tool_registry").add_after_hook(record_file_op)

-- Replace session with [compaction-summary] + last keep_recent messages.
function M.do_compact(keep_recent, summary_text)
  local messages = M.messages()
  local total = #messages
  if keep_recent > total then keep_recent = total end
  local compacted_count = total - keep_recent
  local tail = prelude.drop(messages, compacted_count)

  local read_files, modified_files = M.pending_file_ops()
  local first_kept = tail[1]
  local first_kept_id
  if first_kept then
    local body = prelude.safe_json_decode(first_kept.data, nil)
    if type(body) == "table" then first_kept_id = body.id end
  end

  psi.session_clear()
  M.reset_entry_chain()
  M.append_compaction(summary_text, {
    readFiles = prelude.as_array(read_files),
    modifiedFiles = prelude.as_array(modified_files),
    compactedCount = compacted_count,
    firstKeptEntryId = first_kept_id,
  })
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
