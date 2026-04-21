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

local context = require("psi.context")
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
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
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
  if m and m ~= "" then
    return m
  end
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

-- Translate the v2 session data body into Anthropic's on-wire content
-- shape. pi's `toolCall` becomes Anthropic's `tool_use`; `toolResult`
-- becomes the `tool_result` user-message block. Thinking blocks are
-- skipped (psi doesn't re-send them on the next turn).
local function pi_content_to_anthropic(blocks)
  local out = prelude.as_array({})
  for _, b in ipairs(blocks or {}) do
    if type(b) ~= "table" then
      -- skip
    elseif b.type == "text" then
      out[#out + 1] = { type = "text", text = b.text or "" }
    elseif b.type == "toolCall" then
      out[#out + 1] = { type = "tool_use", id = b.id, name = b.name, input = b.arguments or {} }
    end
  end
  return out
end

local function tool_result_block(msg)
  -- pi stores toolResult.content as an array of content blocks; Anthropic
  -- accepts either a string or an array. We concatenate the text blocks
  -- for simplicity (matches what psi used to send).
  local text = ""
  if type(msg.content) == "table" then
    for _, b in ipairs(msg.content) do
      if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
        text = (text == "" and b.text) or (text .. b.text)
      end
    end
  end
  return {
    type = "tool_result",
    tool_use_id = msg.toolCallId or "",
    content = text,
    is_error = msg.isError and true or false,
  }
end

-- Build the Anthropic messages[] array from session entries.
--
-- Ported from pi-mono's transform-messages.ts:
--   * Assistant messages with stopReason "aborted" or "error" are skipped
--     entirely — their partial content should not be replayed.
--   * Orphan tool_use blocks (assistant with tool_use whose tool_result
--     never landed before the next user message) are resolved with a
--     synthetic tool_result containing "No result provided", isError=true,
--     inserted right before the next user message.
--   * Consecutive tool-result entries are coalesced into one user message.
local function build_api_messages(session)
  local out = {}
  local pending_tool_calls = {} -- tool_use blocks awaiting results
  local seen_result_ids = {} -- tool_use_ids already paired

  local function flush_synthetic_results()
    if #pending_tool_calls == 0 then
      return
    end
    local blocks = prelude.as_array({})
    for _, tc in ipairs(pending_tool_calls) do
      if not seen_result_ids[tc.id] then
        blocks[#blocks + 1] = {
          type = "tool_result",
          tool_use_id = tc.id,
          content = "No result provided",
          is_error = true,
        }
      end
    end
    if #blocks > 0 then
      out[#out + 1] = { role = "user", content = blocks }
    end
    pending_tool_calls = {}
    seen_result_ids = {}
  end

  local i, n = 1, #session
  while i <= n do
    local m = session[i]
    local body = safe_decode(m.data)
    local message = type(body) == "table" and body.message or nil
    local role = m.role

    if role == "assistant" and message then
      local stop = message.stopReason
      if stop == "aborted" or stop == "error" then
        -- Skip entirely; any tool_use blocks here were never dispatched
        -- and are paired with synthetic results below when a user turn
        -- arrives. (No need to track them in pending_tool_calls since
        -- the aborted assistant itself is invisible to the API.)
        i = i + 1
      else
        flush_synthetic_results()
        local content = pi_content_to_anthropic(message.content)
        out[#out + 1] = { role = "assistant", content = content }
        -- Track tool_use blocks for orphan detection on next iteration.
        pending_tool_calls = {}
        seen_result_ids = {}
        if type(message.content) == "table" then
          for _, b in ipairs(message.content) do
            if type(b) == "table" and b.type == "toolCall" then
              pending_tool_calls[#pending_tool_calls + 1] = { id = b.id, name = b.name }
            end
          end
        end
        i = i + 1
      end
    elseif role == "user" and message then
      flush_synthetic_results()
      out[#out + 1] = { role = "user", content = pi_content_to_anthropic(message.content) }
      i = i + 1
    elseif role == "tool-result" then
      local blocks = prelude.as_array({})
      while i <= n and session[i].role == "tool-result" do
        local b = safe_decode(session[i].data)
        if type(b) == "table" and type(b.message) == "table" then
          local tr = tool_result_block(b.message)
          blocks[#blocks + 1] = tr
          if tr.tool_use_id ~= "" then
            seen_result_ids[tr.tool_use_id] = true
          end
        end
        i = i + 1
      end
      if #blocks > 0 then
        out[#out + 1] = { role = "user", content = blocks }
      end
    elseif role == "compaction-summary" then
      flush_synthetic_results()
      local summary = (type(body) == "table" and body.summary) or m.text or ""
      out[#out + 1] = { role = "user", content = summary }
      i = i + 1
    else
      i = i + 1
    end
  end
  flush_synthetic_results()
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
    if not nl then
      break
    end
    local line = buffer:sub(pos, nl - 1)
    -- Strip trailing \r for CRLF servers.
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    pos = nl + 1
    if line:sub(1, 7) == "event: " then
      pending_event = line:sub(8)
    elseif line:sub(1, 6) == "data: " then
      pending_data = line:sub(7)
    elseif line == "" then
      if pending_event and pending_data then
        local data = safe_decode(pending_data)
        if data then
          on_event(pending_event, data)
        end
      end
      pending_event, pending_data = nil, nil
    end
  end
  return buffer:sub(pos)
end

-- ---------- Stream-state accumulator ----------

local function new_state()
  return {
    blocks = {}, -- 1-indexed, mirrors Anthropic's 0-based index+1
    stop_reason = nil,
    assistant_text = "",
    usage = nil, -- merged usage object from message_start + message_delta
    response_id = nil, -- Anthropic server-side message id (from message_start)
  }
end

local function merge_usage(state, u)
  if type(u) ~= "table" then
    return
  end
  state.usage = state.usage or {}
  for _, k in ipairs({
    "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
  }) do
    if type(u[k]) == "number" then
      state.usage[k] = u[k]
    end
  end
end

local function on_message_start(state, data)
  local msg = data.message
  if type(msg) ~= "table" then
    return
  end
  merge_usage(state, msg.usage)
  if type(msg.id) == "string" then
    state.response_id = msg.id
  end
end

local function on_content_block_start(state, data)
  local idx = data.index
  if type(idx) ~= "number" then
    return
  end
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
  if type(idx) ~= "number" then
    return
  end
  local block = state.blocks[idx + 1]
  if not block then
    return
  end
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
  merge_usage(state, data.usage)
end

local function dispatch_sse(state, event_type, data, observer)
  if event_type == "content_block_start" then
    on_content_block_start(state, data)
  elseif event_type == "content_block_delta" then
    on_content_block_delta(state, data, observer)
  elseif event_type == "message_start" then
    on_message_start(state, data)
  elseif event_type == "message_delta" then
    on_message_delta(state, data)
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
  for k, _ in pairs(state.blocks) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local block = state.blocks[k]
    if block.type == "text" then
      content[#content + 1] = { type = "text", text = block.text }
    elseif block.type == "tool_use" then
      local input = (#block.input_json > 0) and safe_decode(block.input_json) or {}
      if type(input) ~= "table" then
        input = {}
      end
      content[#content + 1] = {
        type = "tool_use",
        id = block.id,
        name = block.name,
        input = input,
      }
      tool_uses[#tool_uses + 1] = {
        id = block.id,
        name = block.name,
        input = input,
        input_json = block.input_json,
      }
    end
    -- Thinking blocks intentionally skipped: keep the session JSONL
    -- round-trip compatible with pre-thinking transcripts.
  end
  return content, tool_uses
end

-- ---------- Abort / error bookkeeping ----------
--
-- Matches pi's shape: the partial assistant is persisted as-is (no
-- trimming, no synthesis). Request-build time filters these entries out
-- (see build_api_messages). Orphan tool_use blocks are resolved at
-- request-build time with synthetic "No result provided" tool_results,
-- so we deliberately do NOT emit synthetic results here.
--
-- stop_reason: "aborted" (signal abort) | "error" (network / non-2xx)
local function save_failed_partial(state, model, stop_reason, error_message)
  if not state then
    return
  end
  local has_text = state.assistant_text and state.assistant_text ~= ""
  local has_blocks = next(state.blocks) ~= nil
  if not has_text and not has_blocks then
    return
  end
  local content = finalize_blocks(state)
  session_mod.append_assistant(state.assistant_text or "", content, {
    usage = state.usage,
    stop_reason = stop_reason,
    error_message = error_message,
    model = model,
    provider = "anthropic",
    api = "anthropic-messages",
    response_id = state.response_id,
  })
  context.record_usage(psi.session_message_count(), state.usage)
  session_mod.save()
end

-- ---------- Prompt caching helpers ----------
--
-- Anthropic's ephemeral prompt cache lets subsequent requests in the same
-- session skip re-encoding large prefixes. pi's pattern (ported here):
--   * system prompt: array of text blocks; the last gets cache_control
--   * tools: last tool in the array gets cache_control (caches whole list)
--   * messages: last block of the *final* message gets cache_control
-- Together these create cache breakpoints that persist for ~5 min.

local CACHE_ENV = "PSI_PROMPT_CACHE"

local function caching_enabled()
  local v = os.getenv(CACHE_ENV)
  return v ~= "0" and v ~= "false"
end

local EPHEMERAL = { type = "ephemeral" }

local function system_as_blocks(system_prompt)
  if type(system_prompt) == "table" then
    return system_prompt
  end
  local text = system_prompt or ""
  local block = { type = "text", text = text }
  if caching_enabled() and text ~= "" then
    block.cache_control = EPHEMERAL
  end
  return prelude.as_array({ block })
end

local function tools_with_cache(tool_specs)
  if not caching_enabled() then
    return tool_specs
  end
  local out = prelude.as_array({})
  local n = #tool_specs
  for i, t in ipairs(tool_specs) do
    local copy = {}
    for k, v in pairs(t) do
      copy[k] = v
    end
    if i == n then
      copy.cache_control = EPHEMERAL
    end
    out[#out + 1] = copy
  end
  return out
end

-- Tag the last block of the last message with cache_control. Anthropic
-- accepts cache_control on text, image, tool_use, and tool_result blocks.
local function mark_last_message_cache(messages)
  if not caching_enabled() or #messages == 0 then
    return messages
  end
  local last = messages[#messages]
  if type(last.content) == "string" then
    last.content = prelude.as_array({
      { type = "text", text = last.content, cache_control = EPHEMERAL },
    })
    return messages
  end
  if type(last.content) == "table" and #last.content > 0 then
    local blocks = last.content
    local tail = blocks[#blocks]
    if type(tail) == "table" then
      -- Shallow-copy to avoid mutating session-derived tables.
      local copy = {}
      for k, v in pairs(tail) do
        copy[k] = v
      end
      copy.cache_control = EPHEMERAL
      blocks[#blocks] = copy
    end
  end
  return messages
end

-- ---------- Auto-compaction (threshold check on usage) ----------

local AUTO_COMPACT_ENV = "PSI_AUTO_COMPACT"

local function auto_compact_enabled()
  local v = os.getenv(AUTO_COMPACT_ENV)
  return v ~= "0" and v ~= "false"
end

local function maybe_auto_compact(model, opts)
  if opts and opts.no_auto_compact then
    return
  end
  if not auto_compact_enabled() then
    return
  end
  local over, est = context.should_compact(model)
  if not over then
    return
  end
  io.stderr:write(
    string.format(
      "psi: auto-compacting (context ~%d tokens, threshold %d)\n",
      est.tokens,
      context.context_window(model) - context.reserve_tokens()
    )
  )
  -- Lazy require to avoid a load-time cycle with psi.agent.
  local keep = context.keep_recent_messages(context.keep_recent_tokens())
  local ok, summary = require("psi.agent").run_compact({
    keep_recent = keep,
    model = model,
  })
  if not ok then
    io.stderr:write("psi: auto-compaction failed\n")
  else
    context.reset_usage()
    session_mod.save()
    if summary and summary ~= "" then
      io.stderr:write("psi: compacted; kept " .. tostring(keep) .. " recent messages\n")
    end
  end
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
      { role = "user", content = opts.user_text or "" },
    }),
    stream = false,
  }
  local status, body =
    psi.http_post(api_url(), anthropic_headers(api_key), psi.json_encode(request))
  if status == nil then
    io.stderr:write("http post failed: " .. tostring(body) .. "\n")
    return false
  end
  if status < 200 or status >= 300 then
    io.stderr:write(
      "Anthropic API request failed (" .. tostring(status) .. "): " .. (body or "") .. "\n"
    )
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
  local abort_check = opts.abort_check or function()
    return false
  end

  local headers = anthropic_headers(api_key)
  local url = api_url()

  for _ = 1, MAX_TOOL_ITERATIONS do
    if abort_check() then
      return false, "aborted"
    end

    local session_messages = require("psi.session").messages()
    -- messages() returns Message records; convert to plain alists for
    -- build_api_messages' sake (only role/text/data needed).
    local plain = {}
    for i, m in ipairs(session_messages) do
      plain[i] = { role = m.role, text = m.text, data = m.data }
    end
    local api_messages = build_api_messages(plain)

    local request = {
      model = model,
      max_tokens = max_tokens,
      system = system_as_blocks(system_prompt),
      messages = mark_last_message_cache(api_messages),
      tools = tools_with_cache(tool_specs),
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
      local aborted = abort_check()
      local reason = aborted and "aborted" or "error"
      local emsg = aborted and "Request was aborted" or tostring(err or "http error")
      save_failed_partial(state, model, reason, emsg)
      if not aborted then
        io.stderr:write("http error: " .. emsg .. "\n")
      end
      return false, reason
    end
    if status < 200 or status >= 300 then
      local emsg = string.format("Anthropic API request failed (%d)", status)
      save_failed_partial(state, model, "error", emsg)
      io.stderr:write(emsg .. "\n")
      return false, "error"
    end

    local content, tool_uses = finalize_blocks(state)
    session_mod.append_assistant(state.assistant_text, content, {
      usage = state.usage,
      stop_reason = state.stop_reason,
      model = model,
      provider = "anthropic",
      api = "anthropic-messages",
      response_id = state.response_id,
    })
    context.record_usage(psi.session_message_count(), state.usage)
    session_mod.save()

    if #tool_uses == 0 then
      maybe_auto_compact(model, opts)
      return true, state.assistant_text
    end

    for _, tu in ipairs(tool_uses) do
      if abort_check() then
        -- Any orphan tool_use here will be resolved with a synthetic
        -- "No result provided" tool_result at request-build time on
        -- the next turn (see build_api_messages). Nothing to emit.
        return false, "aborted"
      end

      local input_json = psi.json_encode(tu.input)
      if observer.on_tool_call then
        observer.on_tool_call(tu.id, tu.name, input_json)
      end

      local result_alist = psi.tools.dispatch_alist(tu.name, tu.input)
      local result_json = psi.json_encode(result_alist)
      if observer.on_tool_result then
        observer.on_tool_result(tu.id, tu.name, result_json)
      end

      session_mod.append_tool_result(tu.id, tu.name, result_json, not result_alist.ok)
      session_mod.save()
    end

    maybe_auto_compact(model, opts)
  end

  io.stderr:write(
    "Anthropic tool loop exceeded " .. tostring(MAX_TOOL_ITERATIONS) .. " iterations\n"
  )
  return false
end

return M
