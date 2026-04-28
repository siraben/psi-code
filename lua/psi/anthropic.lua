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
local provider_loop = require("psi.provider_loop")
local sched = require("psi.sched")
local transform = require("psi.message_transform")
local tools = require("psi.tools")
local session_mod = require("psi.session")

local M = {}

local MODEL_ENV = "PSI_ANTHROPIC_MODEL"
local MODEL_DEFAULT = "claude-opus-4-7"
local BASE_URL_ENV = "PSI_ANTHROPIC_BASE_URL"
local BASE_URL_DEFAULT = "https://api.anthropic.com/"

local function api_url()
  local base = os.getenv(BASE_URL_ENV) or BASE_URL_DEFAULT
  if base == "" then
    base = BASE_URL_DEFAULT
  end
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  return base .. "v1/messages"
end

local function anthropic_headers(api_key)
  if api_key == "bridge" and psi.amiga_bridge then
    api_key = "bridge"
  end
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
  local env = os.getenv(MODEL_ENV)
  if env and env ~= "" then
    return env
  end
  return MODEL_DEFAULT
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
-- becomes the `tool_result` user-message block.
--
-- Parity with pi's transform-messages.ts + anthropic.ts:
--   * text: strip lone UTF-16 surrogates (Anthropic rejects them);
--     then skip the block entirely if it's empty-after-trim.
--   * toolCall → tool_use: verbatim id/name, input-object pass-through.
--   * thinking: re-emit with signature so interleaved-thinking stays
--     coherent if thinking is enabled; if the signature is missing
--     (older session or feature-off) fall back to a text block so the
--     reasoning content is not lost.
local function pi_content_to_anthropic(blocks)
  local out = prelude.as_array({})
  for _, b in ipairs(blocks or {}) do
    if type(b) == "table" then
      if b.type == "text" then
        local t = prelude.sanitize_surrogates(b.text or "")
        if prelude.trim(t) ~= "" then
          out[#out + 1] = { type = "text", text = t }
        end
      elseif b.type == "toolCall" then
        out[#out + 1] = { type = "tool_use", id = b.id, name = b.name, input = b.arguments or {} }
      elseif b.type == "thinking" then
        if type(b.thinkingSignature) == "string" and b.thinkingSignature ~= "" then
          out[#out + 1] = {
            type = "thinking",
            thinking = b.thinking or "",
            signature = b.thinkingSignature,
          }
        else
          local t = prelude.sanitize_surrogates(b.thinking or "")
          if prelude.trim(t) ~= "" then
            out[#out + 1] = { type = "text", text = t }
          end
        end
      end
    end
  end
  return out
end

local function tool_result_block(msg)
  -- pi stores toolResult.content as an array of content blocks; Anthropic
  -- accepts either a string or an array. Concatenate text blocks with
  -- "\n" (matches pi) and strip surrogates so the on-wire body is
  -- always valid UTF-8.
  local parts = {}
  if type(msg.content) == "table" then
    for _, b in ipairs(msg.content) do
      if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
        parts[#parts + 1] = b.text
      end
    end
  end
  local text = prelude.sanitize_surrogates(table.concat(parts, "\n"))
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
  -- Every tool_use id we have ever emitted on an assistant message
  -- (across the whole build, not just the current pending set). Used
  -- to drop orphan tool_result blocks whose tool_use was compacted
  -- away: Anthropic rejects those with 400 "unexpected tool_use_id
  -- found in tool_result blocks". Defence-in-depth alongside
  -- session.do_compact's cut-point snap — a stale session loaded
  -- from an older psi that lacked the snap still serialises cleanly.
  local known_tool_use_ids = {}

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
    local message, body = transform.message_body(m)
    local role = m.role

    if role == "assistant" and message then
      if transform.skip_assistant(message) then
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
              if b.id ~= nil and b.id ~= "" then
                known_tool_use_ids[b.id] = true
              end
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
          -- Drop orphan tool_results: those whose tool_use_id was
          -- never emitted on a preceding assistant message (usually
          -- because compaction trimmed the tool_use away). Serialising
          -- the block anyway would 400 the wire request. Matches pi's
          -- compaction-layer guarantee; belt + braces here.
          if tr.tool_use_id ~= "" and known_tool_use_ids[tr.tool_use_id] then
            blocks[#blocks + 1] = tr
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
    elseif
      role == "custom"
      and type(body) == "table"
      and body.__entry_type == "custom_message"
      and type(body.message) == "table"
      and not body.message.hidden
    then
      flush_synthetic_results()
      out[#out + 1] = {
        role = body.message.role == "assistant" and "assistant" or "user",
        content = pi_content_to_anthropic(body.message.content),
      }
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
--
-- `carry` holds parser state that MUST persist across chunk
-- boundaries: `event` (the most recent `event: X` line) and `data`
-- (the most recent `data: Y` line). A blank line finalises them.
--
-- Previously these lived as sse_feed's own locals and were reset on
-- every chunk. If a libcurl chunk ended after `data: {...}\n` but
-- before the `\n\n` terminator, the event was silently dropped —
-- corrupting streamed tool_use JSON and causing the agent to call
-- the tool with empty input ("missing string field: path"). TCP
-- fragmentation + large input_json_delta events made this triggerable.
-- Stateful SSE parser. Replaces the old `leftover = leftover .. chunk`
-- + sse_feed pair, which paid O(N²) in chunk count when an event
-- body was split across many small chunks (Lua strings are
-- immutable; every concat reallocates). Here we accumulate the
-- current in-flight LINE as a table, concat once per `\n`, and
-- never hold a multi-chunk `leftover` string at all.
--
-- State shape:
--   { line = {},              -- table of pending-line chunks
--     pending_event = string|nil,
--     pending_data  = string|nil }
local function new_sse_parser()
  return { line = {}, pending_event = nil, pending_data = nil }
end

local function sse_dispatch_line(parser, line, on_event)
  -- Strip trailing \r for CRLF servers.
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end
  if line:sub(1, 7) == "event: " then
    parser.pending_event = line:sub(8)
  elseif line:sub(1, 6) == "data: " then
    parser.pending_data = line:sub(7)
  elseif line == "" then
    if parser.pending_event and parser.pending_data then
      local data = safe_decode(parser.pending_data)
      if data then
        on_event(parser.pending_event, data)
      end
    end
    parser.pending_event, parser.pending_data = nil, nil
  end
end

local function sse_push(parser, chunk, on_event)
  local start = 1
  local len = #chunk
  while start <= len do
    local nl = chunk:find("\n", start, true)
    if not nl then
      -- No terminator in this chunk; stash the tail and wait for more.
      parser.line[#parser.line + 1] = chunk:sub(start)
      break
    end
    parser.line[#parser.line + 1] = chunk:sub(start, nl - 1)
    local line = table.concat(parser.line)
    parser.line = {}
    sse_dispatch_line(parser, line, on_event)
    start = nl + 1
  end
end

-- ---------- Stream-state accumulator ----------

local function new_state()
  return {
    blocks = {}, -- 1-indexed, mirrors Anthropic's 0-based index+1
    stop_reason = nil,
    assistant_text_parts = {},
    usage = nil, -- merged usage object from message_start + message_delta
    response_id = nil, -- Anthropic server-side message id (from message_start)
  }
end

local function state_assistant_text(state)
  if state.assistant_text ~= nil then
    return state.assistant_text
  end
  state.assistant_text = table.concat(state.assistant_text_parts or {})
  return state.assistant_text
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
    text_parts = cb.text and { cb.text } or {},
    id = cb.id,
    name = cb.name,
    input_json_parts = {},
    thinking_parts = cb.thinking and { cb.thinking } or {},
    signature_parts = cb.signature and { cb.signature } or {},
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
    block.text_parts[#block.text_parts + 1] = d.text
    state.assistant_text_parts[#state.assistant_text_parts + 1] = d.text
    state.assistant_text = nil
    if observer.on_assistant_text_delta then
      observer.on_assistant_text_delta(d.text)
    end
    if psi.events then
      psi.events.emit("assistant-text-delta", { text = d.text })
    end
  elseif d.type == "input_json_delta" and type(d.partial_json) == "string" then
    block.input_json_parts[#block.input_json_parts + 1] = d.partial_json
    if observer.on_tool_call_delta then
      observer.on_tool_call_delta(block.id, d.partial_json)
    end
    if psi.events then
      psi.events.emit("tool-call-delta", { id = block.id, partial_json = d.partial_json })
    end
  elseif d.type == "thinking_delta" and type(d.thinking) == "string" then
    block.thinking_parts[#block.thinking_parts + 1] = d.thinking
    if observer.on_thinking_delta then
      observer.on_thinking_delta(d.thinking)
    end
    if psi.events then
      psi.events.emit("thinking-delta", { text = d.thinking })
    end
  elseif d.type == "signature_delta" and type(d.signature) == "string" then
    -- Anthropic streams the thinking-block signature in one or more
    -- signature_delta events; concatenate for cross-turn replay.
    block.signature_parts[#block.signature_parts + 1] = d.signature
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
      local text = table.concat(block.text_parts or {})
      content[#content + 1] = { type = "text", text = text }
    elseif block.type == "tool_use" then
      local input
      local input_json = table.concat(block.input_json_parts or {})
      if #input_json > 0 then
        input = safe_decode(input_json)
        if type(input) ~= "table" then
          -- Truncated or malformed input_json means stream events
          -- were dropped (SSE chunk-boundary bug, network glitch, or
          -- server truncation). Surface it loudly rather than silently
          -- passing {} — otherwise the agent's next turn sees a
          -- "missing field" error from the tool and wastes a round
          -- trip retrying blindly.
          io.stderr:write(
            string.format(
              "psi: tool_use %s (%s) has malformed input_json (%d bytes, "
                .. "starts with %q); dispatching with empty input\n",
              block.name or "?",
              block.id or "?",
              #input_json,
              input_json:sub(1, 48)
            )
          )
          input = {}
        end
      else
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
        input_json = input_json,
      }
    elseif block.type == "thinking" then
      local thinking = table.concat(block.thinking_parts or {})
      local signature = table.concat(block.signature_parts or {})
      -- Preserve thinking blocks with the streamed signature so the
      -- session JSONL can round-trip through pi's transform-messages
      -- flow. Outgoing-request emission is decided at replay time
      -- (pi_content_to_anthropic) — if no signature survived, the
      -- content falls back to a text block there.
      content[#content + 1] = {
        type = "thinking",
        thinking = thinking,
        signature = signature,
      }
    end
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
  local assistant_text = state_assistant_text(state)
  local has_text = assistant_text ~= ""
  local has_blocks = next(state.blocks) ~= nil
  if not has_text and not has_blocks then
    return
  end
  local content = finalize_blocks(state)
  session_mod.append_assistant(assistant_text, content, {
    usage = state.usage,
    stop_reason = stop_reason,
    error_message = error_message,
    model = model,
    provider = "anthropic",
    api = "anthropic-messages",
    response_id = state.response_id,
  })
  context.record_usage(psi.session_message_count(), state.usage, model)
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

local function http_post_text(url, headers, body, abort_check)
  if not (sched.in_coroutine and sched.in_coroutine()) then
    return psi.http_post(url, headers, body)
  end

  local handle, begin_err = psi.http_stream_begin(url, headers, body)
  if handle == nil then
    return nil, begin_err
  end
  local chunks = {}
  while true do
    if type(abort_check) == "function" and abort_check() then
      psi.http_stream_finish(handle)
      return nil, "aborted"
    end
    local chunk, done = sched.http_poll(handle, 50)
    if chunk ~= nil then
      chunks[#chunks + 1] = chunk
    end
    if done then
      break
    end
  end
  local status = psi.http_stream_finish(handle)
  return status, table.concat(chunks)
end

function M.complete_text(opts)
  local api_key = os.getenv("ANTHROPIC_API_KEY")
  if (not api_key or api_key == "") and psi.amiga_bridge_api_key then
    api_key = psi.amiga_bridge_api_key()
  end
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
  local status, body = http_post_text(
    api_url(),
    anthropic_headers(api_key),
    psi.json_encode(request),
    opts.abort_check
  )
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
  if (not api_key or api_key == "") and psi.amiga_bridge_api_key then
    api_key = psi.amiga_bridge_api_key()
  end
  if not api_key or api_key == "" then
    io.stderr:write("ANTHROPIC_API_KEY is not set\n")
    return false
  end

  local model = resolve_model(opts.model)
  local max_tokens = opts.max_tokens or 16384
  return provider_loop.run_turn({
    model = model,
    max_tokens = max_tokens,
    system_prompt = opts.system_prompt or "",
    tool_specs = opts.tool_specs,
    observer = opts.observer,
    abort_check = opts.abort_check,
    no_auto_compact = opts.no_auto_compact,
  }, {
    provider_name = "anthropic",
    api_name = "anthropic-messages",
    url = api_url(),
    headers = anthropic_headers(api_key),
    tool_specs = api_tool_specs,
    build_messages = function(session)
      return build_api_messages(session)
    end,
    request_body = function(args)
      return {
        model = args.model,
        max_tokens = args.max_tokens,
        system = system_as_blocks(args.system_prompt or ""),
        messages = mark_last_message_cache(args.messages),
        tools = tools_with_cache(args.tool_specs),
        stream = true,
      }
    end,
    new_state = new_state,
    parser_new = new_sse_parser,
    parser_push = function(parser, chunk, state, observer)
      sse_push(parser, chunk, function(event_type, data)
        dispatch_sse(state, event_type, data, observer)
      end)
    end,
    finalize = finalize_blocks,
    persist = function(state, persisted_model, content, _tool_uses, stop_override, error_message)
      session_mod.append_assistant(state_assistant_text(state), content, {
        usage = state.usage,
        stop_reason = stop_override or state.stop_reason,
        error_message = error_message,
        model = persisted_model,
        provider = "anthropic",
        api = "anthropic-messages",
        response_id = state.response_id,
      })
    end,
    response_id = function(state)
      return state.response_id
    end,
    save_failed_partial = save_failed_partial,
    classify_http_error = require("psi.openai_compat").classify_http_error,
    text = state_assistant_text,
    after_iteration = function(iter_model, iter_opts)
      maybe_auto_compact(iter_model, iter_opts)
    end,
  })
end

-- Exported for tests/bench.py only. Safe to drop if internal.
M._test = {
  new_sse_parser = new_sse_parser,
  sse_push = sse_push,
  new_state = new_state,
  dispatch_sse = dispatch_sse,
  finalize_blocks = finalize_blocks,
  state_assistant_text = state_assistant_text,
  build_api_messages = build_api_messages,
}

return M
