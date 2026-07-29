-- psi.session: session accessors, append wrappers, and compaction.
--
-- Disk format is the v3 pi-style schema (ported from pi-mono). The JSONL
-- entries form the durable session tree via id/parentId. In memory we keep
-- only the active branch path in psi's minimal (role, text, data) triple
-- exposed by the C FFI; `data` is a JSON string encoding the entry body
-- minus `type`.
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
-- Branch summary entries use the same in-memory shape with role
-- "branch-summary" and disk type "branch_summary".
--
-- The C FFI exposes:
--   psi.session_message_count()
--   psi.session_messages()            -- array of {role, text, data}
--   psi.session_append(role, text, data_or_nil, token_estimate?)
--   psi.session_clear()

local records = require("psi.records")
local prelude = require("psi.prelude")
local path_util = require("psi.path_utils")

local M = {}

local SESSION_VERSION = 3
local MAX_SESSION_DIR_COMPONENT_BYTES = 180
local PRIVATE_FILE_MODE = tonumber("600", 8)

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

-- ---------- Entry metadata / branch tree ----------

-- C keeps a linear active path. Lua keeps the file's full entry tree and
-- treats leaf_id as the current cursor; appending creates a child of that
-- cursor, and branch navigation rebuilds the active C path from parentId
-- links without dropping sibling branches from the JSONL file.
local last_entry_id = nil
local leaf_id = nil
local file_entries = {}
local entry_by_id = {}
local children_by_parent = {}
local suppress_tree_tracking = false
local reset_branch_tree

function M.reset_entry_chain()
  reset_branch_tree()
end
function M.last_entry_id()
  return last_entry_id
end
function M.leaf_id()
  return leaf_id
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

local function state_home()
  local base = os.getenv("XDG_STATE_HOME")
  if base and base ~= "" then
    return base
  end
  local home = os.getenv("HOME") or ""
  if home == "" then
    return nil
  end
  return prelude.path_join(home, ".local/state")
end

function M.sessions_root()
  local base = state_home()
  if not base then
    return nil
  end
  return prelude.path_join(base, "psi/sessions")
end

local function current_cwd()
  return (psi.cwd and psi.cwd()) or os.getenv("PWD") or "."
end

function M.encode_session_dir(cwd)
  cwd = path_util.resolve(cwd or current_cwd()) or cwd or "."
  local encoded = cwd:gsub(".", function(ch)
    if ch:match("[A-Za-z0-9._-]") then
      return ch
    end
    return string.format("%%%02X", ch:byte())
  end)
  if encoded == "" then
    encoded = "root"
  end
  if #encoded > MAX_SESSION_DIR_COMPONENT_BYTES then
    local suffix = "-" .. prelude.hash_hex(cwd)
    encoded = encoded:sub(1, MAX_SESSION_DIR_COMPONENT_BYTES - #suffix) .. suffix
  end
  return "--" .. encoded .. "--"
end

local function legacy_encode_session_dir(cwd)
  cwd = path_util.resolve(cwd or current_cwd()) or cwd or "."
  local encoded = cwd:gsub("^[/\\]", ""):gsub("[/\\:]", "-")
  if encoded == "" then
    encoded = "root"
  end
  return "--" .. encoded .. "--"
end

function M.session_dir_for_cwd(cwd)
  local root = M.sessions_root()
  if not root then
    return nil
  end
  return prelude.path_join(root, M.encode_session_dir(cwd or current_cwd()))
end

local function session_file_timestamp()
  return (prelude.iso_timestamp():gsub(":", "-"):gsub("%.", "-"))
end

function M.new_session_file_path(cwd, id)
  local dir = M.session_dir_for_cwd(cwd or current_cwd())
  if not dir then
    return nil
  end
  return prelude.path_join(
    dir,
    session_file_timestamp() .. "_" .. (id or prelude.uuid_short()) .. ".jsonl"
  )
end

-- Pick a default on-disk location for the session JSONL. Follows the
-- XDG Base Directory spec:
-- $XDG_STATE_HOME/psi/sessions/<encoded-cwd>/<timestamp>_<id>.jsonl,
-- falling back to $HOME/.local/state/psi/sessions/... Called
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
  local path = M.new_session_file_path(current_cwd(), id)
  if not path then
    return nil
  end
  psi.session_set_path(path)
  return path
end

local function stamp_entry(body)
  body = body or {}
  body.id = body.id or prelude.uuid_short()
  body.timestamp = body.timestamp or prelude.iso_timestamp()
  if body.parentId == nil then
    body.parentId = leaf_id or last_entry_id
  end
  last_entry_id = body.id
  leaf_id = body.id
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
  return { type = "text", text = prelude.decode_utf8_lossy(s or "") }
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

local track_memory_append

-- Cache of the most recent thinking_level_change (known == false means
-- cold: fall back to the scan). Updated on every append that carries
-- one; invalidated when the in-memory session is reset or rebuilt.
local thinking_level_known = false
local thinking_level_value = nil

local function note_thinking_level_body(body)
  if type(body) == "table" and body.__entry_type == "thinking_level_change" then
    thinking_level_known = true
    thinking_level_value = body.thinkingLevel
  end
end

local function append_body(in_mem_role, text, body)
  text = prelude.decode_utf8_lossy(text or "")
  body = prelude.decode_model_value(body)
  psi.session_append(
    in_mem_role,
    text,
    psi.json_encode(body),
    estimate_tokens(in_mem_role, text, body)
  )
  note_thinking_level_body(body)
  if track_memory_append and not suppress_tree_tracking then
    track_memory_append(in_mem_role, text, body)
  end
end

function append_raw(in_mem_role, text, data)
  text = prelude.decode_utf8_lossy(text or "")
  local body = prelude.safe_json_decode(data, nil)
  if type(body) == "table" then
    body = prelude.decode_model_value(body)
    data = psi.json_encode(body)
  end
  local estimate = estimate_tokens(in_mem_role, text, body)
  psi.session_append(in_mem_role, text, data, estimate)
  if type(body) == "table" and body.id then
    last_entry_id = body.id
    leaf_id = body.id
  end
  note_thinking_level_body(body)
  if track_memory_append and not suppress_tree_tracking then
    track_memory_append(in_mem_role, text, body)
  end
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
      local entry = { type = "text", text = prelude.decode_utf8_lossy(b.text or "") }
      if type(b.textSignature) == "string" and b.textSignature ~= "" then
        entry.textSignature = b.textSignature
      end
      out[#out + 1] = entry
    elseif b.type == "tool_use" then
      out[#out + 1] = {
        type = "toolCall",
        id = prelude.decode_utf8_lossy(b.id or ""),
        name = prelude.decode_utf8_lossy(b.name or ""),
        arguments = prelude.decode_model_value(b.input or {}),
      }
    elseif b.type == "thinking" then
      local entry = { type = "thinking", thinking = prelude.decode_utf8_lossy(b.thinking or "") }
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
  text = prelude.decode_utf8_lossy(text or "")
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
  text = prelude.decode_utf8_lossy(text or "")
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

function M.append_tool_result(tool_use_id, tool_name, content_text, is_error, content_blocks)
  content_text = prelude.decode_utf8_lossy(content_text or "")
  local content = prelude.as_array({ text_block(content_text) })
  if type(content_blocks) == "table" and #content_blocks > 0 then
    content = prelude.as_array(prelude.decode_model_value(content_blocks))
  end
  local msg = {
    role = "toolResult",
    toolCallId = prelude.decode_utf8_lossy(tool_use_id or ""),
    toolName = prelude.decode_utf8_lossy(tool_name or ""),
    content = content,
    timestamp = unix_ms(),
  }
  if is_error then
    msg.isError = true
  end
  local body = stamp_entry({ message = msg })
  append_body("tool-result", content_text, body)
end

function M.append_compaction(summary_text, extra)
  summary_text = prelude.decode_utf8_lossy(summary_text or "")
  local body = { summary = summary_text or "" }
  if extra then
    for k, v in pairs(extra) do
      body[k] = prelude.decode_model_value(v)
    end
  end
  body = stamp_entry(body)
  append_body("compaction-summary", summary_text, body)
end

function M.append_branch_summary(summary_text, extra)
  local body = { summary = summary_text or "" }
  if extra then
    for k, v in pairs(extra) do
      body[k] = v
    end
  end
  body = stamp_entry(body)
  append_body("branch-summary", summary_text, body)
  return body.id
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
      hidden = not not opts.hidden,
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
  -- Guard against a bare psi.session_clear() that bypassed the Lua
  -- reset paths: an empty session never has a thinking level.
  if psi.session_message_count() == 0 then
    return nil
  end
  if thinking_level_known then
    return thinking_level_value
  end
  local level = nil
  local msgs = psi.session_messages()
  for i = #msgs, 1, -1 do
    local body = prelude.safe_json_decode(msgs[i].data, nil)
    if type(body) == "table" and body.__entry_type == "thinking_level_change" then
      level = body.thinkingLevel
      break
    end
  end
  thinking_level_known = true
  thinking_level_value = level
  return level
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
    cwd = current_cwd(),
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

-- ---------- Session discovery / resume helpers ----------

local function basename(path)
  path = tostring(path or "")
  return path:match("([^/\\]+)$") or path
end

local function read_first_json_line(path)
  local f <close> = io.open(path, "r")
  if not f then
    return nil
  end
  local line = f:read("*l")
  return prelude.safe_json_decode(line, nil)
end

local function concat_text_blocks(content, separator)
  local parts = prelude.array(type(content) == "table" and #content or 0)
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      parts[#parts + 1] = block.text
    end
  end
  return table.concat(parts, separator), #parts
end

local function entry_text(entry)
  if type(entry) ~= "table" or entry.type ~= "message" or type(entry.message) ~= "table" then
    return nil
  end
  local msg = entry.message
  if msg.role ~= "user" and msg.role ~= "assistant" then
    return nil
  end
  local content = msg.content
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return nil
  end
  local text, count = concat_text_blocks(content, " ")
  if count == 0 then
    return nil
  end
  return text
end

local function parse_time_key(text)
  text = tostring(text or "")
  local y, mo, d, h, mi, s = text:match("(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d)[:-](%d%d)[:-](%d%d)")
  if not y then
    return 0
  end
  return tonumber(y .. mo .. d .. h .. mi .. s) or 0
end

local function preview_label(role)
  if role == "user" then
    return "You"
  elseif role == "assistant" then
    return "Assistant"
  end
  return tostring(role or "Message")
end

local function add_preview_line(preview, role, text)
  if #preview >= 6 or type(text) ~= "string" or text == "" then
    return
  end
  local line = preview_label(role) .. ": " .. text:gsub("%s+", " ")
  if #line > 160 then
    line = line:sub(1, 157) .. "..."
  end
  preview[#preview + 1] = line
end

local function build_session_info(path)
  local f <close> = io.open(path, "r")
  if not f then
    return nil
  end

  local header
  local message_count = 0
  local first_message = nil
  local preview = {}
  local modified_key = 0
  local name = nil

  for line in f:lines() do
    local parsed = prelude.safe_json_decode(line, nil)
    if type(parsed) == "table" then
      if not header then
        if parsed.type ~= "session" then
          return nil
        end
        header = parsed
        modified_key = math.max(modified_key, parse_time_key(parsed.timestamp))
      elseif parsed.type == "message" then
        message_count = message_count + 1
        modified_key = math.max(modified_key, parse_time_key(parsed.timestamp))
        local text = entry_text(parsed)
        if text and text ~= "" and not first_message and parsed.message.role == "user" then
          first_message = text
        end
        if text and text ~= "" then
          add_preview_line(preview, parsed.message.role, text)
        end
      elseif parsed.type == "session_info" and type(parsed.name) == "string" then
        name = prelude.trim(parsed.name)
      else
        modified_key = math.max(modified_key, parse_time_key(parsed.timestamp))
      end
    end
  end
  if not header then
    return nil
  end

  local file_key = parse_time_key(basename(path))
  return {
    path = path,
    id = header.id or "",
    cwd = header.cwd or "",
    name = name or header.name,
    created = header.timestamp or "",
    modified_key = math.max(modified_key, file_key),
    message_count = message_count,
    first_message = first_message or "(no messages)",
    preview = preview,
  }
end

local function collect_jsonl_files(dir, out)
  local entries = dir and psi.list_dir(dir) or nil
  if type(entries) ~= "table" then
    return
  end
  for _, entry in ipairs(entries) do
    local name = type(entry) == "table" and entry.name or entry
    if type(name) == "string" then
      local full = prelude.path_join(dir, name)
      if name:match("%.jsonl$") and psi.file_type(full) == "file" then
        out[#out + 1] = full
      end
    end
  end
end

local function sort_infos(infos)
  table.sort(infos, function(a, b)
    if a.modified_key == b.modified_key then
      return tostring(a.path) > tostring(b.path)
    end
    return a.modified_key > b.modified_key
  end)
  return infos
end

-- Walk every session JSONL under $STATE/psi/sessions, regardless of
-- which cwd they were recorded under. Used by --resume's "all
-- sessions" scope toggle and for cross-project session discovery.
function M.list_all_sessions()
  local root = M.sessions_root()
  if not root then
    return {}
  end
  local files = {}
  collect_jsonl_files(root, files)
  local entries = psi.list_dir(root)
  if type(entries) == "table" then
    for _, entry in ipairs(entries) do
      local name = type(entry) == "table" and entry.name or entry
      if type(name) == "string" then
        local full = prelude.path_join(root, name)
        if psi.file_type(full) == "directory" then
          collect_jsonl_files(full, files)
        end
      end
    end
  end
  local infos = {}
  local seen = {}
  for _, file in ipairs(files) do
    if not seen[file] then
      seen[file] = true
      local info = build_session_info(file)
      if info then
        infos[#infos + 1] = info
      end
    end
  end
  return sort_infos(infos)
end

function M.list_sessions(cwd)
  cwd = path_util.resolve(cwd or current_cwd()) or cwd or current_cwd()
  local files = {}
  collect_jsonl_files(M.session_dir_for_cwd(cwd), files)
  local root = M.sessions_root()
  local legacy_dir = root and prelude.path_join(root, legacy_encode_session_dir(cwd)) or nil
  if legacy_dir ~= M.session_dir_for_cwd(cwd) then
    collect_jsonl_files(legacy_dir, files)
  end

  -- Backward compatibility with the previous flat
  -- $STATE/psi/sessions/<id>.jsonl layout: include files whose header
  -- cwd matches the requested directory.
  local root_entries = root and psi.list_dir(root) or nil
  if type(root_entries) == "table" then
    for _, entry in ipairs(root_entries) do
      local name = type(entry) == "table" and entry.name or entry
      if type(name) == "string" and name:match("%.jsonl$") then
        local full = prelude.path_join(root, name)
        local header = read_first_json_line(full)
        local header_cwd = header and header.cwd
        if
          type(header_cwd) == "string"
          and header_cwd ~= ""
          and path_util.resolve(header_cwd) == cwd
        then
          files[#files + 1] = full
        end
      end
    end
  end

  local infos = {}
  local seen = {}
  for _, file in ipairs(files) do
    if not seen[file] then
      seen[file] = true
      local info = build_session_info(file)
      local info_cwd = info and info.cwd
      if type(info_cwd) == "string" and info_cwd ~= "" and path_util.resolve(info_cwd) == cwd then
        infos[#infos + 1] = info
      end
    end
  end
  return sort_infos(infos)
end

-- Resolve a session id (or unique prefix) to a JSONL path. Looks first
-- in the cwd-scoped session dir, then widens to all session dirs under
-- $STATE/psi/sessions. Filenames follow "<timestamp>_<id>.jsonl" (new)
-- or "<id>.jsonl" (legacy flat layout).
function M.find_session_by_id(id, cwd)
  if type(id) ~= "string" or id == "" then
    return nil, "session id required"
  end
  local seen = {}
  local matches = {}

  local function scan_dir(d)
    if not d then
      return
    end
    local entries = psi.list_dir and psi.list_dir(d) or nil
    if type(entries) ~= "table" then
      return
    end
    for _, entry in ipairs(entries) do
      local name = type(entry) == "table" and entry.name or entry
      if type(name) == "string" and name:match("%.jsonl$") then
        local file_id = name:match("_([^_/]+)%.jsonl$") or name:match("^(.+)%.jsonl$")
        if file_id and (file_id == id or file_id:sub(1, #id) == id) then
          local full = prelude.path_join(d, name)
          if not seen[full] then
            seen[full] = true
            matches[#matches + 1] = { path = full, id = file_id, exact = file_id == id }
          end
        end
      end
    end
  end

  scan_dir(M.session_dir_for_cwd(cwd or current_cwd()))

  local root = M.sessions_root()
  if root then
    local legacy = prelude.path_join(root, legacy_encode_session_dir(cwd or current_cwd()))
    scan_dir(legacy)
    if #matches == 0 then
      scan_dir(root)
      local entries = psi.list_dir(root)
      if type(entries) == "table" then
        for _, entry in ipairs(entries) do
          local name = type(entry) == "table" and entry.name or entry
          if type(name) == "string" then
            local sub = prelude.path_join(root, name)
            if psi.file_type and psi.file_type(sub) == "directory" then
              scan_dir(sub)
            end
          end
        end
      end
    end
  end

  if #matches == 0 then
    return nil, "no session found with id: " .. id
  end
  local exact
  for _, m in ipairs(matches) do
    if m.exact then
      if exact then
        return nil, "ambiguous session id: " .. id
      end
      exact = m
    end
  end
  if exact then
    return exact.path
  end
  if #matches > 1 then
    return nil, "ambiguous session id: " .. id
  end
  return matches[1].path
end

function M.most_recent_session(cwd)
  local infos = M.list_sessions(cwd)
  return infos[1] and infos[1].path or nil
end

function M.describe_session(info)
  if type(info) ~= "table" then
    return ""
  end
  local label = info.name and info.name ~= "" and info.name or info.first_message or "(no messages)"
  label = tostring(label):gsub("%s+", " ")
  if #label > 72 then
    label = label:sub(1, 69) .. "..."
  end
  return string.format(
    "%s  %s  msg:%d",
    tostring(info.created or basename(info.path)),
    label,
    tonumber(info.message_count) or 0
  )
end

function M.resolve_resume_path(cwd, choose)
  local infos = M.list_sessions(cwd)
  if #infos == 0 then
    return nil, "no sessions found for " .. tostring(cwd or current_cwd())
  end
  if #infos == 1 then
    return infos[1].path, nil, infos
  end
  if type(choose) ~= "function" then
    return nil, "multiple sessions found", infos
  end
  local selected = choose(infos)
  if not selected then
    return nil, "no session selected", infos
  end
  if type(selected) == "number" then
    selected = infos[selected] and infos[selected].path or nil
  elseif type(selected) == "table" then
    selected = selected.path
  end
  if type(selected) ~= "string" or selected == "" then
    return nil, "no session selected", infos
  end
  return selected, nil, infos
end

-- Builds a v2 disk entry sharing subtables with `body`; callers treat
-- both as immutable snapshots.
local function disk_entry_from_body(role, text, body)
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
  if role == "compaction-summary" then
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
      out.summary = text or ""
    end
    return out
  end
  if role == "branch-summary" then
    local out = { type = "branch_summary" }
    for _, k in ipairs({
      "id",
      "parentId",
      "timestamp",
      "summary",
      "fromId",
      "readFiles",
      "modifiedFiles",
    }) do
      if body[k] ~= nil then
        out[k] = body[k]
      end
    end
    if out.summary == nil then
      out.summary = text or ""
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

-- Convert an in-memory (role, text, data) record into a v2 disk entry.
local function to_disk_entry(m)
  local body = prelude.safe_json_decode(m.data, nil)
  if type(body) ~= "table" then
    -- Legacy record without a structured body: synthesize one inline.
    -- Must NOT stamp_entry here: save()/fork() invoke this formatter, and
    -- mutating last_entry_id would corrupt the live in-memory chain.
    body = {
      id = prelude.uuid_short(),
      timestamp = prelude.iso_timestamp(),
      message = {
        role = m.role or "user",
        content = prelude.as_array({ text_block(m.text) }),
      },
    }
  end
  return disk_entry_from_body(m.role, m.text, body)
end

local function write_session_file(path, header, messages, count)
  if not psi.mkdir_parent(path) then
    return false, "failed to create parent directory"
  end
  local n = count or #messages

  -- Keep transcript files private from first write.
  if psi.file_write_atomic then
    local parts = prelude.array(n * 2 + 2)
    parts[#parts + 1] = psi.json_encode(header)
    parts[#parts + 1] = "\n"
    for i = 1, n do
      parts[#parts + 1] = psi.json_encode(to_disk_entry(messages[i]))
      parts[#parts + 1] = "\n"
    end
    local ok = psi.file_write_atomic(path, table.concat(parts), PRIVATE_FILE_MODE)
    if ok then
      return true
    end
    return false, "Failed to create session " .. tostring(path)
  end

  local f <close>, err = io.open(path, "w")
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
  if not ok then
    return false, werr
  end
  return true
end

local function write_entry_file(path, header, entries, count)
  if not psi.mkdir_parent(path) then
    return false, "failed to create parent directory"
  end
  local n = count or #entries
  if psi.file_write_atomic then
    local parts = prelude.array(n * 2 + 2)
    parts[#parts + 1] = psi.json_encode(header)
    parts[#parts + 1] = "\n"
    for i = 1, n do
      parts[#parts + 1] = psi.json_encode(entries[i])
      parts[#parts + 1] = "\n"
    end
    local ok = psi.file_write_atomic(path, table.concat(parts), PRIVATE_FILE_MODE)
    if ok then
      return true
    end
    return false, "Failed to create session " .. tostring(path)
  end
  local f <close>, err = io.open(path, "w")
  if not f then
    return false, err
  end
  local ok, werr = pcall(function()
    write_line(f, header)
    for i = 1, n do
      write_line(f, entries[i])
    end
  end)
  if not ok then
    return false, werr
  end
  return true
end

local function append_entry_file(path, entries, from_idx)
  if psi.file_append then
    local parts = prelude.array((#entries - (from_idx or 1) + 1) * 2)
    for i = from_idx or 1, #entries do
      parts[#parts + 1] = psi.json_encode(entries[i])
      parts[#parts + 1] = "\n"
    end
    local ok = psi.file_append(path, table.concat(parts), PRIVATE_FILE_MODE)
    if ok then
      return true
    end
    return false, "Failed to append session entry"
  end
  local f <close>, err = io.open(path, "a")
  if not f then
    return false, err
  end
  local ok, werr = pcall(function()
    for i = from_idx or 1, #entries do
      write_line(f, entries[i])
    end
  end)
  if not ok then
    return false, werr
  end
  return true
end

-- Last-save state for append-only optimisation. Invalidated to
-- force a full rewrite when: the path changes, the file is gone,
-- or the message count shrinks (/new cleared the in-memory session).
local last_saved_path = nil
local last_saved_count = 0
-- Number of active C-session messages known to be mirrored in file_entries.
-- Direct low-level psi.session_append calls bypass track_memory_append and
-- make this diverge, which sends save() through the full reconciliation path.
local tracked_memory_count = 0
local register_file_entry

function reset_branch_tree()
  last_entry_id = nil
  leaf_id = nil
  file_entries = {}
  entry_by_id = {}
  children_by_parent = {}
  tracked_memory_count = 0
  thinking_level_known = false
  thinking_level_value = nil
end

local function reconcile_memory_entries()
  local memory_count = psi.session_message_count()
  if memory_count == tracked_memory_count then
    return
  end
  if memory_count == 0 then
    reset_branch_tree()
    return
  end
  local parent_id = nil
  for _, message in ipairs(psi.session_messages()) do
    local entry = to_disk_entry(message)
    local id = entry.id
    if type(id) == "string" and id ~= "" and entry_by_id[id] then
      parent_id = id
    else
      if entry.parentId == nil then
        entry.parentId = parent_id
      end
      register_file_entry(entry)
      parent_id = entry.id
    end
  end
  tracked_memory_count = memory_count
end

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
--   * message count shrunk (/new cleared the in-memory session — the
--     on-disk earlier entries are stale
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
  reconcile_memory_entries()
  local count = #file_entries

  local force_full = (path ~= last_saved_path)
    or (count < last_saved_count)
    or (last_saved_count == 0)
    or (not psi.file_exists(path))

  if force_full then
    local ok, err = write_entry_file(path, session_header(), file_entries, count)
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

  local ok, err
  ok, err = append_entry_file(path, file_entries, last_saved_count + 1)
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
  leaf_id = body.id or leaf_id
  local role = msg.role
  local text = concat_text_blocks(msg.content, "")
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
  leaf_id = body.id or leaf_id
  append_body("compaction-summary", body.summary, body)
end

local function append_v3_branch_summary(parsed)
  local body = {}
  for _, k in ipairs({
    "id",
    "parentId",
    "timestamp",
    "summary",
    "fromId",
    "readFiles",
    "modifiedFiles",
  }) do
    if parsed[k] ~= nil then
      body[k] = parsed[k]
    end
  end
  last_entry_id = body.id or last_entry_id
  leaf_id = body.id or leaf_id
  append_body("branch-summary", body.summary, body)
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
  leaf_id = body.id or leaf_id
  local text = ""
  if parsed.type == "custom_message" and type(parsed.message) == "table" then
    text = concat_text_blocks(parsed.message.content, "")
  end
  append_body("custom", text, body)
end

local function parent_key(parent_id)
  return parent_id or ""
end

function register_file_entry(entry)
  if type(entry) ~= "table" then
    return
  end
  entry.id = entry.id or prelude.uuid_short()
  entry.timestamp = entry.timestamp or prelude.iso_timestamp()
  file_entries[#file_entries + 1] = entry
  if type(entry.id) == "string" and entry.id ~= "" then
    entry_by_id[entry.id] = entry
    local key = parent_key(entry.parentId)
    local children = children_by_parent[key]
    if not children then
      children = {}
      children_by_parent[key] = children
    end
    children[#children + 1] = entry.id
    leaf_id = entry.id
    last_entry_id = entry.id
  end
end

track_memory_append = function(in_mem_role, text, body)
  if type(body) ~= "table" then
    return
  end
  register_file_entry(disk_entry_from_body(in_mem_role, text or "", body))
  tracked_memory_count = psi.session_message_count()
end

local function active_entries_for_leaf(id)
  local out = {}
  local seen = {}
  while type(id) == "string" and id ~= "" do
    if seen[id] then
      break
    end
    seen[id] = true
    local entry = entry_by_id[id]
    if not entry then
      break
    end
    out[#out + 1] = entry
    id = entry.parentId
  end
  local reversed = {}
  for i = #out, 1, -1 do
    reversed[#reversed + 1] = out[i]
  end
  return reversed
end

local function append_disk_entry_to_memory(entry)
  if entry.type == "message" then
    append_v2_message(entry)
  elseif entry.type == "compaction" then
    append_v2_compaction(entry)
  elseif entry.type == "branch_summary" then
    append_v3_branch_summary(entry)
  elseif
    entry.type == "custom"
    or entry.type == "custom_message"
    or entry.type == "model_change"
    or entry.type == "thinking_level_change"
  then
    append_v3_custom(entry)
  end
end

local function rebuild_active_path()
  psi.session_clear()
  last_entry_id = nil
  -- The rebuilt branch may not contain the previously cached
  -- thinking_level_change; re-derive from the entries replayed below.
  thinking_level_known = false
  thinking_level_value = nil
  local active = active_entries_for_leaf(leaf_id)
  suppress_tree_tracking = true
  for _, entry in ipairs(active) do
    append_disk_entry_to_memory(entry)
  end
  suppress_tree_tracking = false
  if active[#active] and active[#active].id then
    last_entry_id = active[#active].id
    leaf_id = active[#active].id
  else
    last_entry_id = nil
    leaf_id = nil
  end
  tracked_memory_count = psi.session_message_count()
end

local function resolve_entry_id(id_or_prefix)
  if type(id_or_prefix) ~= "string" or id_or_prefix == "" then
    return nil, "entry id required"
  end
  if entry_by_id[id_or_prefix] then
    return id_or_prefix
  end
  local matched
  for id in pairs(entry_by_id) do
    if id:sub(1, #id_or_prefix) == id_or_prefix then
      if matched then
        return nil, "ambiguous entry id: " .. id_or_prefix
      end
      matched = id
    end
  end
  if not matched then
    return nil, "entry not found: " .. id_or_prefix
  end
  return matched
end

function M.branch(id_or_prefix)
  local id, err = resolve_entry_id(id_or_prefix)
  if not id then
    return false, err
  end
  leaf_id = id
  rebuild_active_path()
  return true, id
end

local function ancestor_set(id)
  local out = {}
  local seen = {}
  while type(id) == "string" and id ~= "" and not seen[id] do
    seen[id] = true
    out[id] = true
    local entry = entry_by_id[id]
    id = entry and entry.parentId or nil
  end
  return out
end

local function branch_summary_text(entry)
  if type(entry) ~= "table" then
    return ""
  end
  if entry.type == "message" and type(entry.message) == "table" then
    local msg = entry.message
    if type(msg.content) == "string" then
      return msg.content
    end
    if type(msg.content) == "table" then
      local parts = {}
      for _, block in ipairs(msg.content) do
        if type(block) == "table" then
          if block.type == "text" and type(block.text) == "string" then
            parts[#parts + 1] = block.text
          elseif block.type == "toolCall" then
            parts[#parts + 1] = "[tool call: " .. tostring(block.name or "?") .. "]"
          end
        end
      end
      return table.concat(parts, "\n")
    end
  elseif entry.type == "compaction" or entry.type == "branch_summary" then
    return entry.summary or ""
  elseif entry.type == "custom_message" and type(entry.message) == "table" then
    return branch_summary_text({ type = "message", message = entry.message })
  end
  return ""
end

local function branch_summary_role(entry)
  if entry.type == "message" and type(entry.message) == "table" then
    if entry.message.role == "toolResult" then
      return "tool-result"
    end
    return entry.message.role or "message"
  end
  if entry.type == "compaction" then
    return "compaction-summary"
  end
  if entry.type == "branch_summary" then
    return "branch-summary"
  end
  return entry.type or "entry"
end

function M.branch_entries_to_summarize(target_id_or_prefix)
  local target_id, err = resolve_entry_id(target_id_or_prefix)
  if not target_id then
    return nil, err
  end
  local old_leaf = leaf_id
  if not old_leaf or old_leaf == target_id then
    return {}, target_id, old_leaf, target_id
  end
  local target_ancestors = ancestor_set(target_id)
  local entries = {}
  local id = old_leaf
  local common = nil
  local seen = {}
  while type(id) == "string" and id ~= "" and not seen[id] do
    if target_ancestors[id] then
      common = id
      break
    end
    seen[id] = true
    local entry = entry_by_id[id]
    if not entry then
      break
    end
    entries[#entries + 1] = entry
    id = entry.parentId
  end
  local chronological = {}
  for i = #entries, 1, -1 do
    local entry = entries[i]
    chronological[#chronological + 1] = {
      id = entry.id,
      role = branch_summary_role(entry),
      text = branch_summary_text(entry),
      entry = entry,
    }
  end
  return chronological, target_id, old_leaf, common
end

function M.branch_with_summary(target_id_or_prefix, summary_text, extra)
  local target_id, err = resolve_entry_id(target_id_or_prefix)
  if not target_id then
    return false, err
  end
  local old_leaf = leaf_id
  leaf_id = target_id
  last_entry_id = target_id
  extra = extra or {}
  extra.fromId = extra.fromId or old_leaf
  local summary_id = M.append_branch_summary(summary_text or "", extra)
  rebuild_active_path()
  return true, summary_id
end

local function branch_entry_label(entry)
  local role = entry.type or "entry"
  if entry.type == "message" and type(entry.message) == "table" then
    role = entry.message.role or "message"
  elseif entry.type == "compaction" then
    role = "compaction"
  elseif entry.type == "branch_summary" then
    role = "branch-summary"
  end
  local text = entry_text(entry)
  if (not text or text == "") and entry.type == "compaction" then
    text = entry.summary
  elseif (not text or text == "") and entry.type == "branch_summary" then
    text = entry.summary
  end
  text = tostring(text or ""):gsub("%s+", " ")
  if #text > 70 then
    text = text:sub(1, 67) .. "..."
  end
  return string.format("%s %s", role, text)
end

local function render_branch_lines(parent_id, prefix, lines, seen)
  local children = children_by_parent[parent_key(parent_id)] or {}
  for i, child_id in ipairs(children) do
    if not seen[child_id] then
      seen[child_id] = true
      local entry = entry_by_id[child_id]
      local last = i == #children
      local marker = child_id == leaf_id and "*" or " "
      local elbow = last and "`- " or "|- "
      local child_prefix = prefix .. (last and "   " or "|  ")
      lines[#lines + 1] = string.format(
        "%s%s%s%s  %s",
        marker,
        prefix,
        elbow,
        child_id:sub(1, 8),
        branch_entry_label(entry)
      )
      render_branch_lines(child_id, child_prefix, lines, seen)
    end
  end
end

function M.branch_tree_text()
  if #file_entries == 0 then
    return "(empty session tree)"
  end
  local lines = {
    "session tree (* current leaf)",
    "use /tree <id> to switch branches; add --summarize to absorb the branch you leave",
  }
  render_branch_lines(nil, "", lines, {})
  return table.concat(lines, "\n")
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
          register_file_entry(parsed)
        else
          append_v1_entry(parsed)
        end
      elseif parsed.type == "compaction" then
        register_file_entry(parsed)
      elseif parsed.type == "branch_summary" then
        register_file_entry(parsed)
      elseif
        parsed.type == "custom"
        or parsed.type == "custom_message"
        or parsed.type == "model_change"
        or parsed.type == "thinking_level_change"
      then
        register_file_entry(parsed)
      end
    end
  end
  f:close()

  if psi.session_message_count() == 0 and #file_entries > 0 then
    rebuild_active_path()
  end

  if not psi.session_id() or psi.session_id() == "" then
    psi.session_set_id(prelude.uuid_short())
  end
  -- Stamp the save cursor so subsequent appends write only NEW
  -- entries. The on-disk file already has exactly these messages,
  -- so this is the correct starting point.
  last_saved_path = path
  last_saved_count = #file_entries
  if psi.events and psi.events.emit then
    psi.events.emit("session-start", {
      id = psi.session_id(),
      path = path,
      source = "load",
      message_count = psi.session_message_count(),
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
-- current session file when available. The current session is not modified.
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
    cwd = current_cwd(),
  }
  local parent = psi.session_path() or psi.session_id()
  if parent and parent ~= "" then
    header.parentSession = parent
  end
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
  for k in pairs(t) do
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

function M.install_file_op_hook()
  require("psi.tool_registry").add_after_hook(record_file_op)
end

M.install_file_op_hook()

local function copy_range(messages, first, last)
  local out = {}
  for i = first, last do
    if messages[i] then
      out[#out + 1] = messages[i]
    end
  end
  return out
end

local function add_paths(target, values)
  for _, path in ipairs(type(values) == "table" and values or {}) do
    if type(path) == "string" and path ~= "" then
      target[path] = true
    end
  end
end

local function extract_file_ops(messages, read_files, modified_files)
  for _, entry in ipairs(messages or {}) do
    local body = prelude.safe_json_decode(entry.data, nil)
    local message = type(body) == "table" and body.message or nil
    if type(message) == "table" and message.role == "assistant" then
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if type(block) == "table" and block.type == "toolCall" then
          local args = type(block.arguments) == "table" and block.arguments or {}
          local path = args.path
          if type(path) == "string" and path ~= "" then
            if block.name == "read" then
              read_files[path] = true
            elseif block.name == "write" or block.name == "edit" then
              modified_files[path] = true
            end
          end
        end
      end
    end
  end
end

local function sorted_file_ops(read_files, modified_files)
  local read_only = {}
  local modified = keys_of(modified_files)
  for path in pairs(read_files) do
    if not modified_files[path] then
      read_only[#read_only + 1] = path
    end
  end
  table.sort(read_only)
  return read_only, modified
end

function M.message_token_estimate(message)
  if type(message) ~= "table" then
    return 0
  end
  local body = prelude.safe_json_decode(message.data, nil)
  return estimate_tokens(message.role, message.text, body)
end

-- Select the compaction boundary before generating a summary. The returned
-- plan is then consumed unchanged by both the prompt builder and do_compact,
-- so boundary repair can never discard unsummarized messages.
function M.prepare_compaction(opts)
  opts = opts or {}
  local messages = M.messages()
  local total = #messages
  if total == 0 or messages[total].role == "compaction-summary" then
    return nil
  end

  local first_kept
  local keep_messages = tonumber(opts.keep_recent_messages)
  if keep_messages then
    keep_messages = math.max(0, math.floor(keep_messages))
    first_kept = math.max(1, total - keep_messages + 1)
  else
    local target = tonumber(opts.keep_recent_tokens) or 20000
    local accumulated = 0
    first_kept = total
    for i = total, 1, -1 do
      accumulated = accumulated + M.message_token_estimate(messages[i])
      first_kept = i
      if accumulated >= target then
        break
      end
    end
  end

  local desired_first_kept = first_kept
  while first_kept <= total and messages[first_kept].role == "tool-result" do
    first_kept = first_kept + 1
  end
  if first_kept > total then
    first_kept = desired_first_kept - 1
    while first_kept > 1 and messages[first_kept].role == "tool-result" do
      first_kept = first_kept - 1
    end
  end
  if first_kept > total or first_kept <= 1 then
    return nil
  end

  local compacted_count = first_kept - 1
  local turn_start
  if messages[first_kept].role ~= "user" then
    for i = first_kept - 1, 1, -1 do
      if messages[i].role == "user" then
        turn_start = i
        break
      end
    end
  end

  local history_end = compacted_count
  local turn_prefix = {}
  if turn_start and turn_start <= compacted_count then
    history_end = turn_start - 1
    turn_prefix = copy_range(messages, turn_start, compacted_count)
  end

  local previous_summary
  local messages_to_summarize = {}
  local read_files = {}
  local modified_files = {}
  for _, entry in ipairs(copy_range(messages, 1, history_end)) do
    if entry.role == "compaction-summary" then
      local body = prelude.safe_json_decode(entry.data, nil)
      previous_summary = type(body) == "table" and body.summary or entry.text
      if type(body) == "table" then
        add_paths(read_files, body.readFiles)
        add_paths(modified_files, body.modifiedFiles)
      end
    else
      messages_to_summarize[#messages_to_summarize + 1] = entry
    end
  end
  extract_file_ops(messages_to_summarize, read_files, modified_files)
  extract_file_ops(turn_prefix, read_files, modified_files)
  local read_list, modified_list = sorted_file_ops(read_files, modified_files)

  return {
    messages = messages,
    total = total,
    first_kept = first_kept,
    compacted_count = compacted_count,
    keep_recent = total - compacted_count,
    messages_to_summarize = messages_to_summarize,
    turn_prefix = turn_prefix,
    is_split_turn = #turn_prefix > 0,
    tail = copy_range(messages, first_kept, total),
    previous_summary = previous_summary,
    read_files = read_list,
    modified_files = modified_list,
  }
end

-- Replace the active in-memory path with [compaction-summary] + the last
-- keep_recent messages. The durable JSONL tree is append-only: sibling
-- branches remain in file_entries, and the compacted active path is appended
-- as a new branch rather than rewriting the whole file.
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
function M.do_compact(plan, summary_text)
  if type(plan) ~= "table" then
    plan = M.prepare_compaction({ keep_recent_messages = plan })
  end
  if not plan then
    return false, "session is already small enough"
  end
  local messages = plan.messages
  local total = plan.total
  local compacted_count = plan.compacted_count
  local keep_recent = plan.keep_recent
  local tail = plan.tail

  if psi.events and psi.events.emit then
    psi.events.emit("compaction-start", {
      total = total,
      keep_recent = keep_recent,
      compacted = compacted_count,
      reason = plan.reason,
    })
  end

  local read_files = plan.read_files or {}
  local modified_files = plan.modified_files or {}
  local first_kept = tail[1]
  local first_kept_id
  if first_kept then
    local body = prelude.safe_json_decode(first_kept.data, nil)
    if type(body) == "table" then
      first_kept_id = body.id
    end
  end
  local summary_parent_id = nil
  if compacted_count > 0 and messages[1] then
    local first_body = prelude.safe_json_decode(messages[1].data, nil)
    if type(first_body) == "table" then
      summary_parent_id = first_body.parentId
    end
  end

  psi.session_clear()
  last_entry_id = summary_parent_id
  leaf_id = summary_parent_id
  M.append_compaction(summary_text, {
    readFiles = prelude.as_array(read_files),
    modifiedFiles = prelude.as_array(modified_files),
    compactedCount = compacted_count,
    firstKeptEntryId = first_kept_id,
    tokensBefore = plan.tokens_before,
  })
  for _, m in ipairs(tail) do
    local body = prelude.safe_json_decode(m.data, nil)
    if type(body) == "table" then
      body.id = nil
      body.timestamp = nil
      body.parentId = last_entry_id
      append_body(m.role, m.text, stamp_entry(body))
    else
      append_raw(m.role, m.text, m.data)
    end
  end
  M.reset_file_ops()

  if psi.events and psi.events.emit then
    psi.events.emit("compaction-end", {
      total = total,
      keep_recent = keep_recent,
      compacted = compacted_count,
      summary = summary_text,
      reason = plan.reason,
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
