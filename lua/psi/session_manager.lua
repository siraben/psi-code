-- psi.session: session accessors, append wrappers, and compaction.
--
-- Disk format is the v3 pi-style schema (ported from pi-mono). In memory
-- we still use psi's minimal (role, text, data) triple exposed by the C
-- FFI; `data` is a JSON string encoding the entry body minus `type`.
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
--   psi.session_append(role, text, data_or_nil, token_estimate?)
--   psi.session_clear()

local records = require("psi.records")
local prelude = require("psi.prelude")

local M = {}

local SESSION_VERSION = 3

-- Optional display name set via /name; persisted into the session header
-- so it survives reloads.
local display_name = nil
function M.display_name()
  return display_name
end
function M.set_display_name(n)
  if type(n) == "string" and n ~= "" then
    display_name = n
  else
    display_name = nil
  end
end

-- ---------- Entry metadata (id/parent threading) ----------

-- The in-memory entry chain is strictly linear, so we only need the id
-- of the most recently appended entry as the parent for the next one.
local last_entry_id = nil

function M.reset_entry_chain()
  last_entry_id = nil
end
function M.last_entry_id()
  return last_entry_id
end

-- Make sure the host session has a stable UUID before the first
-- stream event fires. Historically we only assigned one lazily
-- inside M.save(), and only when a session path was already set —
-- so extensions that hooked `after-provider-response` and asked
-- for psi.session_id() on their first flush got nil and had to
-- fall back to a timestamp filename (see the autosave debug
-- session under i686-transcripts/). Call this anywhere a fresh
-- entry is about to be persisted or observed by an extension.
function M.ensure_id()
  if not psi.session_id() or psi.session_id() == "" then
    psi.session_set_id(prelude.uuid_short())
  end
end

-- Pick a default on-disk location for the session JSONL. Follows the
-- XDG Base Directory spec: $XDG_STATE_HOME/psi/sessions/<id>.jsonl,
-- falling back to $HOME/.local/state/psi/sessions/<id>.jsonl. Called
-- when the host (TUI) starts a session without --session, so every
-- turn's autosave has somewhere to land instead of returning
-- "no session path set" and surfacing "failed to save session file"
-- in the status line.
function M.ensure_default_path()
  local current = psi.session_path()
  if current and current ~= "" then
    return current
  end
  M.ensure_id()
  local id = psi.session_id()
  local base = os.getenv("XDG_STATE_HOME")
  if not base or base == "" then
    local home = os.getenv("HOME") or ""
    if home == "" then
      return nil
    end
    base = prelude.path_join(home, ".local/state")
  end
  local dir = prelude.path_join(base, "psi/sessions")
  local path = prelude.path_join(dir, id .. ".jsonl")
  psi.session_set_path(path)
  return path
end

local function stamp_entry(body)
  body = body or {}
  body.id = body.id or prelude.uuid_short()
  body.timestamp = body.timestamp or prelude.iso_timestamp()
  if body.parentId == nil then
    body.parentId = last_entry_id
  end
  last_entry_id = body.id
  -- Every appended entry is an observable event for extensions,
  -- so the session id must be stable by now.
  M.ensure_id()
  return body
end

function M.count()
  return psi.session_message_count()
end

function M.messages()
  return records.messages_from_alists(psi.session_messages())
end

function M.messages_from(start_index)
  return records.messages_from_alists(psi.session_messages_from(start_index or 1))
end

local append_raw

-- Internal: append an in-memory message record verbatim (used when
-- reconstructing state during compaction). Does not re-stamp metadata.
function M.append_message(msg)
  append_raw(msg.role, msg.text, msg.data)
end

-- ---------- Append wrappers (pi-shape content builders) ----------

local function text_block(s)
  return { type = "text", text = s or "" }
end

local function ceil_div(n, d)
  return math.floor((n + d - 1) / d)
end

local function token_chars_to_tokens(chars)
  if chars <= 0 then
    return 0
  end
  return ceil_div(chars, 4)
end

local function calibrate_tokens(pi_tokens)
  return ceil_div(pi_tokens * 221, 200)
end

local function json_len(value)
  if value == nil then
    return 0
  end
  return #(psi.json_encode(value) or "")
end

local function content_chars(content, opts)
  opts = opts or {}
  if type(content) == "string" then
    return #content
  end
  if type(content) ~= "table" then
    return 0
  end
  local chars = 0
  for _, block in ipairs(content) do
    if type(block) == "table" then
      if block.type == "text" then
        chars = chars + #(block.text or "")
      elseif opts.thinking and block.type == "thinking" then
        chars = chars + #(block.thinking or "")
      elseif opts.thinking and block.type == "toolCall" then
        chars = chars + #(block.name or "") + json_len(block.arguments)
      elseif opts.images and block.type == "image" then
        chars = chars + 4800
      end
    end
  end
  return chars
end

local function pi_tokens_for_body(in_mem_role, text, body)
  if type(body) ~= "table" then
    return token_chars_to_tokens(#(text or ""))
  end
  local msg = body.message
  if type(msg) == "table" then
    if msg.role == "assistant" then
      return token_chars_to_tokens(content_chars(msg.content, { thinking = true }))
    elseif msg.role == "toolResult" or msg.role == "custom" then
      return token_chars_to_tokens(content_chars(msg.content, { images = true }))
    elseif msg.role == "bashExecution" then
      return token_chars_to_tokens(#(msg.command or "") + #(msg.output or ""))
    end
    return token_chars_to_tokens(content_chars(msg.content))
  elseif in_mem_role == "compaction-summary" or in_mem_role == "branch-summary" then
    return token_chars_to_tokens(#(body.summary or text or ""))
  end
  return token_chars_to_tokens(#(text or ""))
end

local function estimate_tokens(in_mem_role, text, body)
  return calibrate_tokens(pi_tokens_for_body(in_mem_role, text, body))
end

local function append_body(in_mem_role, text, body)
  psi.session_append(
    in_mem_role,
    text or "",
    psi.json_encode(body),
    estimate_tokens(in_mem_role, text, body)
  )
end

function append_raw(in_mem_role, text, data)
  local body = prelude.safe_json_decode(data, nil)
  local estimate = estimate_tokens(in_mem_role, text, body)
  psi.session_append(in_mem_role, text or "", data, estimate)
end

-- pi normalizes Anthropic's verbose usage keys.
local function normalize_usage(u)
  if type(u) ~= "table" then
    return nil
  end
  local input = u.input_tokens or u.input or 0
  local output = u.output_tokens or u.output or 0
  local cr = u.cache_read_input_tokens or u.cacheRead or 0
  local cw = u.cache_creation_input_tokens or u.cacheWrite or 0
  return {
    input = input,
    output = output,
    cacheRead = cr,
    cacheWrite = cw,
    totalTokens = input + output + cr + cw,
  }
end

-- Store pi-style canonical stop reasons. Anthropic emits snake_case over
-- the wire, while OpenAI-compatible providers use their own strings.
local STOP_REASON_CANONICAL = {
  end_turn = "stop",
  tool_use = "toolUse",
  stop_sequence = "stopSequence",
  max_tokens = "length",
  pause_turn = "pauseTurn",
  refusal = "refusal",
  stop = "stop",
  length = "length",
  error = "error",
  aborted = "aborted",
}
local function normalize_stop_reason(r)
  if type(r) ~= "string" then
    return nil
  end
  return STOP_REASON_CANONICAL[r] or r
end

local function unix_ms()
  if not (psi and psi.amiga_bridge) then
    return math.floor(os.time() * 1000)
  end
  -- Avoid large floating-point intermediates on classic AmigaOS math libraries.
  return 0
end

local function pi_content_from_blocks(blocks)
  local out = prelude.as_array({})
  for _, b in ipairs(blocks or {}) do
    if b.type == "text" then
      local entry = { type = "text", text = b.text or "" }
      if type(b.textSignature) == "string" and b.textSignature ~= "" then
        entry.textSignature = b.textSignature
      end
      out[#out + 1] = entry
    elseif b.type == "tool_use" then
      out[#out + 1] = { type = "toolCall", id = b.id, name = b.name, arguments = b.input or {} }
    elseif b.type == "thinking" then
      local entry = { type = "thinking", thinking = b.thinking or "" }
      -- Anthropic emits the signature as `signature`; pi's session
      -- schema renames it to `thinkingSignature`. Preserve for replay.
      if type(b.signature) == "string" and b.signature ~= "" then
        entry.thinkingSignature = b.signature
      end
      out[#out + 1] = entry
    end
  end
  return out
end

function M.append_user(text)
  local body = stamp_entry({
    message = {
      role = "user",
      content = prelude.as_array({ text_block(text) }),
      timestamp = unix_ms(),
    },
  })
  append_body("user", text, body)
end

-- Public extension API: inject a message into the in-memory session
-- without triggering an agent turn. role is "user" | "assistant".
-- Use this to prime a conversation, replay a logged prompt, or have
-- an extension post a note that the model will see on the next turn.
-- Use psi.session.save() afterwards if you want it persisted.
--
-- This is the supported wrapper over M.append_user / M.append_assistant
-- (which are marked internal). Prefer send_message from extension code.
function M.send_message(role, text)
  if role == "user" then
    M.append_user(text or "")
    return true
  elseif role == "assistant" then
    -- Minimal metadata; extension-injected text doesn't have usage
    -- stats or a model. Callers that need those should call
    -- append_assistant directly.
    M.append_assistant(text or "", { { type = "text", text = text or "" } }, {})
    return true
  end
  return false, "unsupported role: " .. tostring(role)
end

-- blocks: Anthropic-shape array (type=text|tool_use|thinking).
-- opts: {usage?, stop_reason?, error_message?, model?, provider?, response_id?, api?}
function M.append_assistant(text, blocks, opts)
  opts = opts or {}
  local msg = { role = "assistant", content = pi_content_from_blocks(blocks) }
  msg.timestamp = unix_ms()
  local usage = normalize_usage(opts.usage)
  if usage then
    msg.usage = usage
  end
  local stop = normalize_stop_reason(opts.stop_reason)
  if stop then
    msg.stopReason = stop
  end
  if opts.error_message then
    msg.errorMessage = opts.error_message
  end
  if opts.model then
    msg.model = opts.model
  end
  if opts.provider then
    msg.provider = opts.provider
  end
  if opts.api then
    msg.api = opts.api
  end
  if opts.response_id then
    msg.responseId = opts.response_id
  end
  local body = stamp_entry({ message = msg })
  append_body("assistant", text, body)
end

function M.append_tool_result(tool_use_id, tool_name, content_text, is_error)
  local msg = {
    role = "toolResult",
    toolCallId = tool_use_id,
    toolName = tool_name,
    content = prelude.as_array({ text_block(content_text) }),
    timestamp = unix_ms(),
  }
  if is_error then
    msg.isError = true
  end
  local body = stamp_entry({ message = msg })
  append_body("tool-result", content_text, body)
end

function M.append_compaction(summary_text, extra)
  local body = { summary = summary_text or "" }
  if extra then
    for k, v in pairs(extra) do
      body[k] = v
    end
  end
  body = stamp_entry(body)
  append_body("compaction-summary", summary_text, body)
end

function M.append_custom(name, data)
  local body = stamp_entry({
    __entry_type = "custom",
    name = name or "custom",
    data = data or {},
  })
  append_body("custom", "", body)
end

function M.append_custom_message(text, opts)
  opts = opts or {}
  local body = stamp_entry({
    __entry_type = "custom_message",
    message = {
      role = opts.role or "user",
      content = prelude.as_array({ text_block(text or "") }),
      timestamp = unix_ms(),
      hidden = opts.hidden and true or false,
    },
  })
  append_body("custom", text, body)
end

function M.append_model_change(model)
  local body = stamp_entry({ __entry_type = "model_change", model = model or "" })
  append_body("custom", "", body)
end

function M.append_thinking_level_change(level)
  local body = stamp_entry({ __entry_type = "thinking_level_change", thinkingLevel = level or "" })
  append_body("custom", "", body)
end

function M.current_thinking_level()
  local msgs = psi.session_messages()
  for i = #msgs, 1, -1 do
    local body = prelude.safe_json_decode(msgs[i].data, nil)
    if type(body) == "table" and body.__entry_type == "thinking_level_change" then
      return body.thinkingLevel
    end
  end
  return nil
end

-- ---------- JSONL persistence ----------

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
  if parent and parent ~= "" then
    hdr.parentSession = parent
  end
  if display_name and display_name ~= "" then
    hdr.name = display_name
  end
  return hdr
end

-- Convert an in-memory (role, text, data) record into a v2 disk entry.
local function to_disk_entry(m)
  local body = prelude.safe_json_decode(m.data, nil)
  if type(body) ~= "table" then
    -- Legacy/synthetic record with no structured body: synthesize one
    -- inline. Must NOT call stamp_entry here — to_disk_entry is a
    -- formatter invoked by save() and fork(), and mutating
    -- last_entry_id would corrupt the live in-memory chain with the
    -- ids of records being serialized. fork() in particular promises
    -- "current session is not modified".
    body = {
      id = prelude.uuid_short(),
      timestamp = prelude.iso_timestamp(),
      message = {
        role = m.role or "user",
        content = prelude.as_array({ text_block(m.text) }),
      },
    }
  end
  if body.__entry_type == "custom" then
    return {
      type = "custom",
      id = body.id,
      parentId = body.parentId,
      timestamp = body.timestamp,
      name = body.name,
      data = body.data,
    }
  end
  if body.__entry_type == "custom_message" then
    return {
      type = "custom_message",
      id = body.id,
      parentId = body.parentId,
      timestamp = body.timestamp,
      message = body.message,
    }
  end
  if body.__entry_type == "model_change" then
    return {
      type = "model_change",
      id = body.id,
      parentId = body.parentId,
      timestamp = body.timestamp,
      model = body.model,
    }
  end
  if body.__entry_type == "thinking_level_change" then
    return {
      type = "thinking_level_change",
      id = body.id,
      parentId = body.parentId,
      timestamp = body.timestamp,
      thinkingLevel = body.thinkingLevel,
    }
  end
  if m.role == "compaction-summary" then
    local out = { type = "compaction" }
    for _, k in ipairs({
      "id",
      "parentId",
      "timestamp",
      "summary",
      "firstKeptEntryId",
      "tokensBefore",
      "readFiles",
      "modifiedFiles",
      "compactedCount",
    }) do
      if body[k] ~= nil then
        out[k] = body[k]
      end
    end
    if out.summary == nil then
      out.summary = m.text or ""
    end
    return out
  end
  local out = { type = "message" }
  for _, k in ipairs({ "id", "parentId", "timestamp", "message" }) do
    if body[k] ~= nil then
      out[k] = body[k]
    end
  end
  return out
end

local function write_session_file(path, header, messages, count)
  if not psi.mkdir_parent(path) then
    return false, "failed to create parent directory"
  end
  local n = count or #messages

  -- Atomic temp+fsync+rename so a crash mid-write can't leave a
  -- truncated session log. The host primitive caps content at 16 MiB;
  -- larger sessions fall through to the streamed writer below.
  if psi.file_write_atomic then
    local parts = prelude.array(n * 2 + 2)
    parts[#parts + 1] = psi.json_encode(header)
    parts[#parts + 1] = "\n"
    for i = 1, n do
      parts[#parts + 1] = psi.json_encode(to_disk_entry(messages[i]))
      parts[#parts + 1] = "\n"
    end
    if psi.file_write_atomic(path, table.concat(parts)) then
      return true
    end
  end

  local f, err = io.open(path, "w")
  if not f then
    return false, err
  end
  -- pcall so a mid-write failure (disk full, ENOSPC, killed process)
  -- still closes the descriptor rather than leaking it until GC.
  local ok, werr = pcall(function()
    write_line(f, header)
    for i = 1, n do
      write_line(f, to_disk_entry(messages[i]))
    end
  end)
  f:close()
  if not ok then
    return false, werr
  end
  return true
end

-- Append-only companion to write_session_file. Called on every save
-- after the first when the message count has only grown — writes
-- messages[from_idx..#messages] to the existing file without
-- rewriting the header or earlier entries. A 100-entry session
-- with a 5-entry delta drops from 105-line rewrite to 5-line
-- append; on iSH this turns a ~50ms save into a ~2ms append.
-- The full delta goes out as one fwrite; psi.file_append fsyncs
-- before close, so a successful return means it's on disk.
local function append_session_file(path, messages)
  local parts = prelude.array(#messages * 2)
  for i = 1, #messages do
    parts[#parts + 1] = psi.json_encode(to_disk_entry(messages[i]))
    parts[#parts + 1] = "\n"
  end
  local content = table.concat(parts)
  if #content == 0 then
    return true
  end
  if not psi.file_append(path, content) then
    return false, "file_append failed"
  end
  return true
end

-- Last-save state for append-only optimisation. Invalidated to
-- force a full rewrite when: the path changes, the file is gone,
-- or the message count shrinks (compaction / clear).
local last_saved_path = nil
local last_saved_count = 0

-- Persist the current session to disk.
--
-- Return contract:
--   true                           — wrote the file (or all entries
--                                    were already on disk; no-op).
--   false, "no session path set"   — no path configured; nothing was
--                                    written. Distinguishable from a
--                                    true write so extensions that
--                                    track flushes (e.g. autosave)
--                                    can tell a no-op apart from a
--                                    real save. Historically this
--                                    returned `true` silently and
--                                    hid the misconfiguration.
--   false, err                     — disk / permission / I/O error.
--
-- Append-only fast path: after the first successful save, later
-- saves append the new entries instead of rewriting the whole
-- file. Conditions that force a full rewrite:
--   * path changed (`/resume`, fork to new file)
--   * file is missing on disk
--   * message count shrunk (compaction or /new cleared the
--     in-memory session — the on-disk earlier entries are stale
--     and must be replaced)
--   * first ever save for this path
function M.save(path)
  M.ensure_id()
  if not path or path == "" then
    path = psi.session_path()
  end
  if not path or path == "" then
    return false, "no session path set"
  end
  local count = psi.session_message_count()

  local force_full = (path ~= last_saved_path)
    or (count < last_saved_count)
    or (last_saved_count == 0)
    or (not psi.file_exists(path))

  if force_full then
    local messages = psi.session_messages()
    local ok, err = write_session_file(path, session_header(), messages, count)
    if ok then
      last_saved_path = path
      last_saved_count = count
    else
      -- Failed rewrite leaves the file in an uncertain state; the
      -- next successful save will force another full rewrite.
      last_saved_path = nil
      last_saved_count = 0
    end
    return ok, err
  end

  if count == last_saved_count then
    return true
  end

  local messages = psi.session_messages_from(last_saved_count + 1)
  local ok, err = append_session_file(path, messages)
  if ok then
    last_saved_count = count
  else
    last_saved_path = nil
    last_saved_count = 0
  end
  return ok, err
end

-- ---------- Loader: v2 native + v1 upconvert ----------

-- v1 assistant.data was a JSON string of Anthropic content blocks
-- (type=text|tool_use). Map it into the v2 `message.content` shape.
local function v1_assistant_data_to_v2(raw, text)
  local blocks = prelude.safe_json_decode(raw, nil)
  if type(blocks) ~= "table" then
    return { role = "assistant", content = prelude.as_array({ text_block(text) }) }
  end
  return { role = "assistant", content = pi_content_from_blocks(blocks) }
end

-- v1 tool-result `text` field held a JSON blob:
-- {tool_use_id, tool, content, is_error}. Lift into v2 toolResult.
local function v1_tool_result_text_to_v2(text)
  local parsed = prelude.safe_json_decode(text, nil)
  if type(parsed) ~= "table" then
    return {
      role = "toolResult",
      toolCallId = "",
      toolName = "",
      content = prelude.as_array({ text_block(text) }),
    }
  end
  local msg = {
    role = "toolResult",
    toolCallId = parsed.tool_use_id or "",
    toolName = parsed.tool or "",
    content = prelude.as_array({ text_block(parsed.content or "") }),
  }
  if parsed.is_error then
    msg.isError = true
  end
  return msg
end

local function append_v1_entry(parsed)
  local role = parsed.role or "custom"
  local text = parsed.text or ""
  if role == "user" then
    M.append_user(text)
  elseif role == "assistant" then
    local msg = v1_assistant_data_to_v2(parsed.data, text)
    local body = stamp_entry({ message = msg })
    append_body("assistant", text, body)
  elseif role == "tool-result" then
    local msg = v1_tool_result_text_to_v2(text)
    local body = stamp_entry({ message = msg })
    append_body("tool-result", text, body)
  elseif role == "compaction-summary" then
    -- v1 data held provenance JSON; preserve under v2 keys.
    local extra = prelude.safe_json_decode(parsed.data, nil)
    if type(extra) ~= "table" then
      extra = {}
    end
    M.append_compaction(text, extra)
  else
    append_raw(role, text, parsed.data)
  end
end

local function append_v2_message(parsed)
  local msg = parsed.message
  if type(msg) ~= "table" then
    return
  end
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
  if role == "toolResult" then
    in_mem_role = "tool-result"
  end
  append_body(in_mem_role, text, body)
end

local function append_v2_compaction(parsed)
  local body = {}
  for _, k in ipairs({
    "id",
    "parentId",
    "timestamp",
    "summary",
    "firstKeptEntryId",
    "tokensBefore",
    "readFiles",
    "modifiedFiles",
    "compactedCount",
  }) do
    if parsed[k] ~= nil then
      body[k] = parsed[k]
    end
  end
  last_entry_id = body.id or last_entry_id
  append_body("compaction-summary", body.summary, body)
end

local function append_v3_custom(parsed)
  local body = {
    __entry_type = parsed.type,
    id = parsed.id,
    parentId = parsed.parentId,
    timestamp = parsed.timestamp,
    name = parsed.name,
    data = parsed.data,
    message = parsed.message,
    model = parsed.model,
    thinkingLevel = parsed.thinkingLevel,
  }
  last_entry_id = body.id or last_entry_id
  local text = ""
  if parsed.type == "custom_message" and type(parsed.message) == "table" then
    for _, b in ipairs(parsed.message.content or {}) do
      if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
        text = (text == "" and b.text) or (text .. b.text)
      end
    end
  end
  append_body("custom", text, body)
end

function M.load(path)
  if not path or path == "" then
    return false, "no path"
  end
  psi.session_set_path(path)

  -- Any previously-cached save cursor belongs to a different
  -- session file. Clear it so the first save after load re-opens
  -- the append cursor against this file's actual length.
  last_saved_path = nil
  last_saved_count = 0

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
  display_name = nil

  local version = 1
  for line in f:lines() do
    local parsed = prelude.safe_json_decode(line)
    if type(parsed) == "table" then
      if parsed.type == "session" then
        version = parsed.version or 1
        if parsed.id then
          psi.session_set_id(parsed.id)
        end
        if parsed.parent then
          psi.session_set_parent_id(parsed.parent)
        elseif parsed.parentSession then
          psi.session_set_parent_id(parsed.parentSession)
        end
        display_name = type(parsed.name) == "string" and parsed.name or nil
      elseif parsed.type == "message" then
        if version >= 2 and parsed.message then
          append_v2_message(parsed)
        else
          append_v1_entry(parsed)
        end
      elseif parsed.type == "compaction" then
        append_v2_compaction(parsed)
      elseif
        parsed.type == "custom"
        or parsed.type == "custom_message"
        or parsed.type == "model_change"
        or parsed.type == "thinking_level_change"
      then
        append_v3_custom(parsed)
      end
    end
  end
  f:close()

  if not psi.session_id() or psi.session_id() == "" then
    psi.session_set_id(prelude.uuid_short())
  end
  -- Stamp the save cursor so subsequent appends write only NEW
  -- entries. The on-disk file already has exactly these messages,
  -- so this is the correct starting point.
  last_saved_path = path
  last_saved_count = psi.session_message_count()
  if psi.events and psi.events.emit then
    psi.events.emit("session-start", {
      id = psi.session_id(),
      path = path,
      source = "load",
      message_count = last_saved_count,
    })
  end
  return true
end

-- Fire session-start for the freshly-initialised session whose path
-- was picked via ensure_default_path (or set via --session). Called
-- from C right after runtime init so extensions see a single lifecycle
-- event regardless of whether the session was loaded from disk or
-- created fresh.
function M.announce_start()
  if not psi.events or not psi.events.emit then
    return
  end
  psi.events.emit("session-start", {
    id = psi.session_id(),
    path = psi.session_path() or "",
    source = "new",
    message_count = psi.session_message_count(),
  })
end

-- Symmetric with session-start. Host calls this once, just before
-- exit, so subscribers can flush logs / close fds / write a summary.
-- Idempotent: if no subscribers or no events bus, no-op.
function M.announce_shutdown()
  if not psi.events or not psi.events.emit then
    return
  end
  psi.events.emit("session-shutdown", {
    id = psi.session_id(),
    path = psi.session_path() or "",
    message_count = psi.session_message_count(),
  })
end

-- Write the first `at_count` messages of the current session to a new
-- JSONL file at `out_path`, stamped with a fresh id whose parent is the
-- current session id. The current session is not modified.
function M.fork(at_count, out_path)
  if not out_path or out_path == "" then
    return false, "no path"
  end
  local messages = psi.session_messages()
  if at_count > #messages then
    at_count = #messages
  end
  if at_count < 0 then
    at_count = 0
  end
  local header = {
    type = "session",
    version = SESSION_VERSION,
    id = prelude.uuid_short(),
    timestamp = prelude.iso_timestamp(),
    cwd = os.getenv("PWD") or ".",
    parentSession = psi.session_id(),
  }
  return write_session_file(out_path, header, messages, at_count)
end

-- ---------- file-op tracking for compaction provenance ----------

local pending_read = {}
local pending_modified = {}

local function record_file_op(name, input, result)
  if not (result and result.ok) then
    return
  end
  if not (input and type(input.path) == "string") then
    return
  end
  if name == "read" then
    pending_read[input.path] = true
  elseif name == "write" or name == "edit" then
    pending_modified[input.path] = true
  end
end

local function keys_of(t)
  local out = {}
  for k, _ in pairs(t) do
    out[#out + 1] = k
  end
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
--
-- Fires `compaction-start` before the rewrite and `compaction-end`
-- after, so extensions (autosave, exporters, observers) can flush or
-- snapshot the transcript on either side. Mirrors pi's
-- `compaction_start` / `compaction_end` agent events.
--
-- Payload for both events:
--   { total = <pre-rewrite message count>,
--     keep_recent = <requested retention>,
--     compacted = <messages that will be/were folded into the summary> }
-- compaction-end additionally gets `summary = <text>`.
function M.do_compact(keep_recent, summary_text)
  local messages = M.messages()
  local total = #messages
  if keep_recent > total then
    keep_recent = total
  end
  local compacted_count = total - keep_recent

  -- Snap the compaction boundary forward past any leading tool-result
  -- entries in the retained tail. Otherwise a cut that lands between
  -- an assistant's toolCall and its toolResult drops the call but
  -- keeps the result — the wire request then has a tool_result with
  -- no matching tool_use and Anthropic rejects it with:
  --   400 "unexpected tool_use_id found in tool_result blocks ... Each
  --        tool_result block must have a corresponding tool_use block
  --        in the previous message"
  -- Mirrors pi-mono's findValidCutPoints (compaction/compaction.ts:
  -- 299-337) which disqualifies toolResult messages as cut points.
  while
    compacted_count < total
    and messages[compacted_count + 1]
    and messages[compacted_count + 1].role == "tool-result"
  do
    compacted_count = compacted_count + 1
  end
  local tail = prelude.drop(messages, compacted_count)

  if psi.events and psi.events.emit then
    psi.events.emit("compaction-start", {
      total = total,
      keep_recent = keep_recent,
      compacted = compacted_count,
    })
  end

  local read_files, modified_files = M.pending_file_ops()
  local first_kept = tail[1]
  local first_kept_id
  if first_kept then
    local body = prelude.safe_json_decode(first_kept.data, nil)
    if type(body) == "table" then
      first_kept_id = body.id
    end
  end

  psi.session_clear()
  M.reset_entry_chain()
  M.append_compaction(summary_text, {
    readFiles = prelude.as_array(read_files),
    modifiedFiles = prelude.as_array(modified_files),
    compactedCount = compacted_count,
    firstKeptEntryId = first_kept_id,
  })
  for _, m in ipairs(tail) do
    M.append_message(m)
  end
  M.reset_file_ops()

  if psi.events and psi.events.emit then
    psi.events.emit("compaction-end", {
      total = total,
      keep_recent = keep_recent,
      compacted = compacted_count,
      summary = summary_text,
    })
  end
  return true
end

function M.role_prefix(message)
  local role = message.role
  if role == "user" then
    return "User: "
  end
  if role == "assistant" then
    return "Assistant: "
  end
  if role == "tool-call" then
    return "Tool call: "
  end
  if role == "tool-result" then
    return "Tool result: "
  end
  if role == "compaction-summary" then
    return "Previous summary: "
  end
  if role == "branch-summary" then
    return "Branch summary: "
  end
  return "Message: "
end

return M
