-- psi.anthropic: agent turn loop + one-shot completions.
--
-- Entry points:
--   M.run_turn(opts) — streaming tool-dispatch loop; drives an
--       assistant turn given the current session state. Returns
--       (ok, final_text_or_error).
--   M.complete_text(opts) — non-streaming one-shot completion used
--       for background jobs like compaction summarization.
--
-- Caller supplies:
--   opts.system_prompt     string
--   opts.model             string or nil (falls back to env / default)
--   opts.max_tokens        integer
--   opts.tool_specs        array of tool-spec alists (filtered API shape)
--   opts.observer          table with optional callbacks; see
--                          agent.h struct psi_agent_observer
--   opts.abort_check       function() -> bool (true means abort)
--   opts.user_text         string (for complete_text only)
--
-- Session transcript is read and written via psi.session_* primitives.

local prelude = require("psi.prelude")
local tools = require("psi.tools")
local session_mod = require("psi.session")

local M = {}

local MODEL_ENV = "PSI_ANTHROPIC_MODEL"
local MODEL_DEFAULT = "claude-opus-4-7"
local BASE_URL_ENV = "PSI_ANTHROPIC_BASE_URL"
local BASE_URL_DEFAULT = "https://api.anthropic.com/"
local MAX_TOOL_ITERATIONS = 32

local function api_url()
  local base = os.getenv(BASE_URL_ENV) or BASE_URL_DEFAULT
  if base:sub(-1) ~= "/" then base = base .. "/" end
  return base .. "v1/messages"
end

local function anthropic_headers(api_key)
  return {
    "content-type: application/json",
    "anthropic-version: 2023-06-01",
    "x-api-key: " .. api_key,
  }
end

local function resolve_model(m)
  if m and m ~= "" then return m end
  return os.getenv(MODEL_ENV) or MODEL_DEFAULT
end

-- Tool specs for the API: drop prompt_snippet + prompt_guidelines,
-- keep only name/description/input_schema.
local function api_tool_specs(user_text)
  local full = tools.select_specs(user_text or "")
  local out = prelude.as_array({})
  for _, t in ipairs(full) do
    out[#out + 1] = {
      name = t.name,
      description = t.description,
      input_schema = t.input_schema,
    }
  end
  return out
end

-- ---------- Session -> API messages ----------

local safe_decode = prelude.safe_json_decode

-- Build the Anthropic messages[] array from the session's ordered
-- entries. Mirrors pi's model: assistant messages carry tool_use
-- blocks inside their content (via the stored data_json); tool-result
-- entries are first-class user messages keyed by tool_use_id. No
-- separate tool-call record type exists.
--
--   user/assistant: content = parsed data_json OR plain text.
--   compaction-summary: fold into a single user message.
--   tool-result run: coalesce consecutive results into one user message.
local function build_api_messages(session)
  local out = {}
  local i = 1
  local n = #session
  while i <= n do
    local msg = session[i]
    local role = msg.role
    if role == "user" or role == "assistant" then
      local decoded = safe_decode(msg.data)
      local content = decoded or (msg.text or "")
      out[#out + 1] = {role = role, content = content}
      i = i + 1
    elseif role == "compaction-summary" then
      out[#out + 1] = {role = "user", content = msg.text or ""}
      i = i + 1
    elseif role == "tool-result" then
      local content = prelude.as_array({})
      while i <= n and session[i].role == "tool-result" do
        local parsed = safe_decode(session[i].text)
        if parsed and type(parsed.tool_use_id) == "string" and type(parsed.content) == "string" then
          content[#content + 1] = {
            type = "tool_result",
            tool_use_id = parsed.tool_use_id,
            content = parsed.content,
            is_error = parsed.is_error and true or false,
          }
        end
        i = i + 1
      end
      out[#out + 1] = {role = "user", content = content}
    else
      i = i + 1
    end
  end
  return prelude.as_array(out)
end

-- ---------- SSE parser ----------

-- Feed stream buffer, call on_event(event_type, data_table) for each
-- complete event, return leftover bytes that didn't form a full event.
local function sse_feed(buffer, on_event)
  local pending_event = nil
  local pending_data = nil
  local pos = 1
  while true do
    local nl = buffer:find("\n", pos, true)
    if not nl then break end
    local line = buffer:sub(pos, nl - 1)
    -- Strip trailing \r for CRLF servers.
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    pos = nl + 1
    if line:sub(1, 7) == "event: " then
      pending_event = line:sub(8)
    elseif line:sub(1, 6) == "data: " then
      pending_data = line:sub(7)
    elseif line == "" then
      if pending_event and pending_data then
        local data = safe_decode(pending_data)
        if data then on_event(pending_event, data) end
      end
      pending_event, pending_data = nil, nil
    end
  end
  return buffer:sub(pos)
end

-- ---------- Stream-state accumulator ----------

local function new_state()
  return {
    blocks = {},          -- 1-indexed, mirrors Anthropic's 0-based index+1
    stop_reason = nil,
    assistant_text = "",
  }
end

local function on_content_block_start(state, data)
  local idx = data.index
  if type(idx) ~= "number" then return end
  local cb = data.content_block or {}
  state.blocks[idx + 1] = {
    type = cb.type or "text",
    text = cb.text or "",
    id = cb.id,
    name = cb.name,
    input_json = "",
    thinking = cb.thinking or "",
  }
end

local function on_content_block_delta(state, data, observer)
  local idx = data.index
  if type(idx) ~= "number" then return end
  local block = state.blocks[idx + 1]
  if not block then return end
  local d = data.delta or {}
  if d.type == "text_delta" and type(d.text) == "string" then
    block.text = block.text .. d.text
    state.assistant_text = state.assistant_text .. d.text
    if observer.on_assistant_text_delta then
      observer.on_assistant_text_delta(d.text)
    end
  elseif d.type == "input_json_delta" and type(d.partial_json) == "string" then
    block.input_json = block.input_json .. d.partial_json
    if observer.on_tool_call_delta then
      observer.on_tool_call_delta(block.id, d.partial_json)
    end
  elseif d.type == "thinking_delta" and type(d.thinking) == "string" then
    block.thinking = block.thinking .. d.thinking
    if observer.on_thinking_delta then
      observer.on_thinking_delta(d.thinking)
    end
  end
end

local function on_message_delta(state, data)
  if type(data.delta) == "table" and type(data.delta.stop_reason) == "string" then
    state.stop_reason = data.delta.stop_reason
  end
end

local function dispatch_sse(state, event_type, data, observer)
  if     event_type == "content_block_start" then on_content_block_start(state, data)
  elseif event_type == "content_block_delta" then on_content_block_delta(state, data, observer)
  elseif event_type == "message_delta"        then on_message_delta(state, data)
  end
end

-- ---------- Content-block -> session encoding ----------

-- Returns (assistant_content_array_for_session, tool_use_blocks).
local function finalize_blocks(state)
  local content = prelude.as_array({})
  local tool_uses = {}
  -- state.blocks is a 1-indexed table but may be sparse if Anthropic
  -- skipped indices; iterate with pairs then sort by key.
  local keys = {}
  for k, _ in pairs(state.blocks) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local block = state.blocks[k]
    if block.type == "text" then
      content[#content + 1] = {type = "text", text = block.text}
    elseif block.type == "tool_use" then
      local input = (#block.input_json > 0) and safe_decode(block.input_json) or {}
      if type(input) ~= "table" then input = {} end
      content[#content + 1] = {
        type = "tool_use", id = block.id, name = block.name, input = input
      }
      tool_uses[#tool_uses + 1] = {
        id = block.id, name = block.name, input = input, input_json = block.input_json,
      }
    end
    -- Thinking blocks intentionally skipped: keep the session JSONL
    -- round-trip compatible with pre-thinking transcripts.
  end
  return content, tool_uses
end

-- ---------- One-shot completion (non-streaming) ----------

function M.complete_text(opts)
  local api_key = os.getenv("ANTHROPIC_API_KEY")
  if not api_key or api_key == "" then
    io.stderr:write("ANTHROPIC_API_KEY is not set\n")
    return false
  end
  local request = {
    model = resolve_model(opts.model),
    max_tokens = opts.max_tokens or 2048,
    system = opts.system_prompt or "",
    messages = prelude.as_array({
      {role = "user", content = opts.user_text or ""},
    }),
    stream = false,
  }
  local status, body = psi.http_post(api_url(), anthropic_headers(api_key),
                                      psi.json_encode(request))
  if status == nil then
    io.stderr:write("http post failed: " .. tostring(body) .. "\n")
    return false
  end
  if status < 200 or status >= 300 then
    io.stderr:write("Anthropic API request failed (" .. tostring(status) .. "): " ..
                    (body or "") .. "\n")
    return false
  end
  local parsed = safe_decode(body)
  if not parsed or type(parsed.content) ~= "table" then
    return false
  end
  local text_parts = {}
  for _, block in ipairs(parsed.content) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      text_parts[#text_parts + 1] = block.text
    end
  end
  return true, table.concat(text_parts)
end

-- ---------- Agent turn (streaming + tool loop) ----------

function M.run_turn(opts)
  local api_key = os.getenv("ANTHROPIC_API_KEY")
  if not api_key or api_key == "" then
    io.stderr:write("ANTHROPIC_API_KEY is not set\n")
    return false
  end

  local observer = opts.observer or {}
  local model = resolve_model(opts.model)
  local max_tokens = opts.max_tokens or 16384
  local system_prompt = opts.system_prompt or ""
  local tool_specs = opts.tool_specs or api_tool_specs("")
  local abort_check = opts.abort_check or function() return false end

  local headers = anthropic_headers(api_key)
  local url = api_url()

  for _ = 1, MAX_TOOL_ITERATIONS do
    if abort_check() then return false, "aborted" end

    local session_messages = require("psi.session").messages()
    -- messages() returns Message records; convert to plain alists for
    -- build_api_messages' sake (only role/text/data needed).
    local plain = {}
    for i, m in ipairs(session_messages) do
      plain[i] = {role = m.role, text = m.text, data = m.data}
    end
    local api_messages = build_api_messages(plain)

    local request = {
      model = model,
      max_tokens = max_tokens,
      system = system_prompt,
      messages = api_messages,
      tools = tool_specs,
      stream = true,
    }
    local body = psi.json_encode(request)

    local state = new_state()
    local leftover = ""
    local status, err = psi.http_post_stream(url, headers, body, function(chunk)
      leftover = leftover .. chunk
      leftover = sse_feed(leftover, function(event_type, data)
        dispatch_sse(state, event_type, data, observer)
      end)
    end)

    if status == nil then
      if abort_check() then return false, "aborted" end
      io.stderr:write("http error: " .. tostring(err) .. "\n")
      return false
    end
    if status < 200 or status >= 300 then
      io.stderr:write("Anthropic API request failed (" .. tostring(status) .. ")\n")
      return false
    end

    local content, tool_uses = finalize_blocks(state)
    psi.session_append("assistant", state.assistant_text, psi.json_encode(content))
    session_mod.save()

    if #tool_uses == 0 then
      return true, state.assistant_text
    end

    for _, tu in ipairs(tool_uses) do
      if abort_check() then return false, "aborted" end

      local input_json = psi.json_encode(tu.input)
      if observer.on_tool_call then
        observer.on_tool_call(tu.id, tu.name, input_json)
      end

      local result_alist = psi.tools.dispatch_alist(tu.name, tu.input)
      local result_json = psi.json_encode(result_alist)
      if observer.on_tool_result then
        observer.on_tool_result(tu.id, tu.name, result_json)
      end

      psi.session_append("tool-result", psi.json_encode({
        tool_use_id = tu.id,
        tool = tu.name,
        content = result_json,
        is_error = not result_alist.ok,
      }))
      session_mod.save()
    end
  end

  io.stderr:write("Anthropic tool loop exceeded " ..
                  tostring(MAX_TOOL_ITERATIONS) .. " iterations\n")
  return false
end

return M
