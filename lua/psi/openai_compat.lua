-- psi.openai_compat: shared machinery for OpenAI-flavoured
-- chat/completions providers.
--
-- Both Ollama (native `POST /api/chat`) and OpenRouter (OpenAI
-- `POST /v1/chat/completions`) speak an "OpenAI-ish" wire format:
-- messages list with `role`, tool calls represented as
-- `{role:"assistant", tool_calls:[{id, function:{name, arguments}}]}`,
-- tool results as `{role:"tool", content}`. The exact shape,
-- streaming format, and a handful of quirks (fragmented arguments,
-- cached_tokens disambiguation, done signal) differ per provider —
-- but the surrounding skeleton (session → messages, run_turn loop,
-- concurrent tool dispatch, session persistence, event emission) is
-- identical.
--
-- This module owns that skeleton. Each provider (psi.ollama,
-- psi.openrouter) supplies a small bag of callbacks + metadata:
--
--   cfg.provider_name        string    "ollama" | "openrouter" | …
--   cfg.api_name             string    "ollama-chat" | "openrouter-chat-completions"
--   cfg.url                  string    full URL for streaming chat
--   cfg.headers              array     HTTP headers
--   cfg.request_body(args)   table     args = {messages, tool_specs, model,
--                                              max_tokens, abort}; returns
--                                              the body table to JSON-encode.
--   cfg.parser_new()                   returns a fresh parser state (table)
--   cfg.parser_push(parser, chunk, state, observer)
--                                      feeds one raw chunk; advances state,
--                                      fires observer callbacks.
--   cfg.finalize_tool_calls(state)     -> [{id, name, arguments_table}, …]
--   cfg.tool_result_message(tool_call_id, tool_name, text)
--                                      -> {role="tool", …} shape for
--                                      build_api_messages.
--   cfg.assistant_tool_call(block)     translates an in-session
--                                      {type="toolCall", id, name,
--                                      arguments} into the tool_calls[i]
--                                      shape this provider expects.
--   cfg.include_response_id  bool      if true, pass state.response_id to
--                                      session.append_assistant (OpenRouter).

local context = require("psi.context")
local prelude = require("psi.prelude")
local tools = require("psi.tools")
local session_mod = require("psi.session")

local M = {}

local MAX_TOOL_ITERATIONS = 32

local safe_decode = prelude.safe_json_decode

-- ---------- HTTP error classification ----------
--
-- When a provider returns a non-2xx status, the response body is
-- typically a JSON error envelope. Common shapes:
--   {"error": {"message": "...", "type": "..."}}   (OpenAI, Anthropic, OpenRouter)
--   {"error": "..."}                                (some Ollama builds)
-- Extract the most informative string we can and prepend an
-- HTTP-status-specific hint when it tells the user something
-- actionable. Matches pi-mono's error-body passthrough behaviour
-- so operators don't have to tail stderr to learn what went wrong.
function M.classify_http_error(status, body, provider_name)
  local detail = nil
  if type(body) == "string" and body ~= "" then
    local parsed = safe_decode(body)
    if type(parsed) == "table" then
      local err = parsed.error
      if type(err) == "table" then
        detail = err.message or err.type or err.code
      elseif type(err) == "string" then
        detail = err
      elseif type(parsed.message) == "string" then
        detail = parsed.message
      end
    end
    if not detail then
      -- No structured error — include a short trimmed snippet so
      -- the user sees SOMETHING rather than just the status code.
      local trimmed = body:gsub("%s+", " "):sub(1, 200)
      if trimmed ~= "" then detail = trimmed end
    end
  end

  local hint = nil
  if status == 401 or status == 403 then
    hint = "check your API key"
  elseif status == 429 then
    hint = "rate limited — retry after a moment or switch model"
  elseif status == 404 then
    hint = "model or endpoint not found — check the model slug"
  elseif status == 413 then
    hint = "request too large — context or output may need trimming"
  elseif status == 529 or status == 503 then
    hint = "provider is overloaded — try again shortly"
  elseif status >= 500 then
    hint = "provider-side error — retry or check status page"
  end

  local parts = { string.format("%s request failed (%d)", provider_name, status) }
  if hint   then parts[#parts + 1] = "— " .. hint   end
  if detail then parts[#parts + 1] = "— " .. detail end
  return table.concat(parts, " ")
end

-- ---------- Tool specs (identical across both providers) ----------

function M.api_tool_specs(user_text)
  local full = tools.select_specs(user_text or "")
  local out = prelude.as_array({})
  for _, t in ipairs(full) do
    out[#out + 1] = {
      type = "function",
      ["function"] = {
        name = t.name,
        description = t.description,
        parameters = t.input_schema,
      },
    }
  end
  return out
end

-- ---------- Session -> OpenAI-style messages ----------
--
-- Chronological, no coalescing. Aborted/error assistants are skipped
-- (matches pi's transform-messages). Orphan tool_use blocks are
-- followed up with synthetic "No result provided" tool messages so
-- the next API turn doesn't reject them.
function M.build_api_messages(session, system_prompt, cfg)
  local tool_result_message = cfg.tool_result_message
  local assistant_tool_call = cfg.assistant_tool_call
  local out = {}
  if system_prompt and system_prompt ~= "" then
    out[#out + 1] = { role = "system", content = system_prompt }
  end

  local pending_tool_calls = {}
  local seen_result_ids = {}
  -- Every tool_call id that has ever been emitted on an assistant
  -- message so far. Used to drop orphan tool-result entries whose
  -- matching tool_call was compacted away. See anthropic.lua for the
  -- same defence and session.do_compact for the cut-point snap that
  -- prevents the orphan from happening in the first place.
  local known_tool_use_ids = {}

  local function flush_synthetic_results()
    for _, tc in ipairs(pending_tool_calls) do
      if not seen_result_ids[tc.id] then
        out[#out + 1] = tool_result_message(tc.id, tc.name, "No result provided")
      end
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

    if role == "user" and message then
      flush_synthetic_results()
      local text = ""
      for _, b in ipairs(message.content or {}) do
        if type(b) == "table" and b.type == "text" and type(b.text) == "string" then
          text = (text == "" and b.text) or (text .. b.text)
        end
      end
      out[#out + 1] = { role = "user", content = text }
      i = i + 1
    elseif role == "assistant" and message then
      local stop = message.stopReason
      if stop == "aborted" or stop == "error" then
        i = i + 1
      else
        flush_synthetic_results()
        local text = ""
        local tool_calls = nil
        for _, b in ipairs(message.content or {}) do
          if type(b) == "table" then
            if b.type == "text" and type(b.text) == "string" then
              text = (text == "" and b.text) or (text .. b.text)
            elseif b.type == "toolCall" then
              tool_calls = tool_calls or {}
              tool_calls[#tool_calls + 1] = assistant_tool_call(b)
            end
          end
        end
        local entry = { role = "assistant" }
        if text ~= "" then entry.content = text end
        if tool_calls then entry.tool_calls = tool_calls end
        out[#out + 1] = entry

        pending_tool_calls = {}
        seen_result_ids = {}
        if tool_calls then
          for _, tc in ipairs(tool_calls) do
            pending_tool_calls[#pending_tool_calls + 1] =
              { id = tc.id, name = tc["function"].name }
            if tc.id ~= nil and tc.id ~= "" then
              known_tool_use_ids[tc.id] = true
            end
          end
        end
        i = i + 1
      end
    elseif role == "tool-result" then
      while i <= n and session[i].role == "tool-result" do
        local b = safe_decode(session[i].data)
        if type(b) == "table" and type(b.message) == "table" then
          local tm = b.message
          local text = ""
          if type(tm.content) == "table" then
            for _, cb in ipairs(tm.content) do
              if type(cb) == "table" and cb.type == "text" and type(cb.text) == "string" then
                text = (text == "" and cb.text) or (text .. cb.text)
              end
            end
          end
          local tid = tm.toolCallId or ""
          -- Skip orphans: a tool-result whose tool_call was compacted
          -- away (never emitted on a preceding assistant message).
          -- Serialising it would trip the OpenAI-compat server with
          -- "tool_call_id not found" or similar.
          if tid ~= "" and known_tool_use_ids[tid] then
            out[#out + 1] = tool_result_message(tid, tm.toolName or "", text)
            seen_result_ids[tid] = true
          end
        end
        i = i + 1
      end
    elseif role == "compaction-summary" then
      flush_synthetic_results()
      local summary = (type(body) == "table" and body.summary) or m.text or ""
      out[#out + 1] = { role = "user", content = summary }
      i = i + 1
    elseif role == "custom"
        and type(body) == "table"
        and body.__entry_type == "custom_message"
        and type(body.message) == "table"
        and not body.message.hidden then
      flush_synthetic_results()
      local text = ""
      for _, cb in ipairs(body.message.content or {}) do
        if type(cb) == "table" and cb.type == "text" and type(cb.text) == "string" then
          text = (text == "" and cb.text) or (text .. cb.text)
        end
      end
      out[#out + 1] = {
        role = body.message.role == "assistant" and "assistant" or "user",
        content = text,
      }
      i = i + 1
    else
      i = i + 1
    end
  end
  flush_synthetic_results()
  return prelude.as_array(out)
end

-- ---------- Persist assistant + tool_calls in v2 session shape ----------

function M.persist_assistant(state, model, tool_calls, cfg, stop_override, error_message)
  local blocks = {}
  -- Reasoning-model thinking (Qwen3, DeepSeek-R1, …) arrives via a
  -- separate field on the wire and is accumulated by the provider's
  -- parser into state.thinking. Persist it as a thinking block so
  -- the session keeps a full record — the Lua-side assistant text
  -- column still tracks only visible content.
  if type(state.thinking) == "string" and state.thinking ~= "" then
    blocks[#blocks + 1] = { type = "thinking", thinking = state.thinking }
  end
  if state.text ~= "" then
    blocks[#blocks + 1] = { type = "text", text = state.text }
  end
  for _, tc in ipairs(tool_calls) do
    blocks[#blocks + 1] = {
      type = "tool_use", id = tc.id, name = tc.name, input = tc.arguments,
    }
  end
  local meta = {
    usage = state.usage,
    stop_reason = stop_override or state.stop_reason,
    error_message = error_message,
    model = model,
    provider = cfg.provider_name,
    api = cfg.api_name,
  }
  if cfg.include_response_id then
    meta.response_id = state.response_id
  end
  session_mod.append_assistant(state.text, blocks, meta)
end

-- ---------- Streaming agent turn ----------
--
-- Generic against the OpenAI-compat request/response flow. Providers
-- own the URL + headers + request body shape + stream parser +
-- delta handler; everything else (the tool loop, the sched
-- round-robin for concurrent dispatch, session persistence, event
-- emission) lives here so a bug fix lands once.
function M.run_turn(opts, cfg)
  local observer = opts.observer or {}
  local model = opts.model or ""
  local system_prompt = opts.system_prompt or ""
  local tool_specs = opts.tool_specs or M.api_tool_specs("")
  local abort_check = opts.abort_check or function() return false end
  local sched = require("psi.sched")

  for _ = 1, MAX_TOOL_ITERATIONS do
    if abort_check() then return false, "aborted" end

    local session_messages = session_mod.messages()
    local plain = {}
    for i, m in ipairs(session_messages) do
      plain[i] = { role = m.role, text = m.text, data = m.data }
    end
    local api_messages = M.build_api_messages(plain, system_prompt, cfg)

    -- Fire `context` so extensions can mutate the messages array
    -- before it hits the wire (RAG injection, stripping noisy tool
    -- results, mid-context compression, etc.). Subscribers mutate
    -- payload.messages in place — the array is shared, not copied,
    -- so standard table ops (insert/remove/assign) take effect.
    -- Keep this cheap: it runs once per turn iteration, so a slow
    -- handler directly delays the provider call.
    if psi.events then
      psi.events.emit("context", {
        messages = api_messages,
        model = model,
        provider = cfg.provider_name,
        system_prompt = system_prompt,
      })
    end

    local body = cfg.request_body({
      model = model,
      messages = api_messages,
      tool_specs = tool_specs,
      max_tokens = opts.max_tokens,
    })
    if psi.events then
      psi.events.emit("before-provider-request", {
        provider = cfg.provider_name,
        model = model,
        body = body,
      })
    end

    local state = cfg.new_state()
    local parser = cfg.parser_new()
    -- Collect the raw response body alongside the streaming parser
    -- (capped at 16 KiB) so we can parse a structured error out of
    -- it if the server returns non-2xx. Normal streams are large
    -- (many MB) but the cap only matters for error bodies, which
    -- are always small JSON objects.
    local raw_body = {}
    local raw_body_len = 0
    local RAW_BODY_MAX = 16 * 1024

    local handle, begin_err = psi.http_stream_begin(
      cfg.url, cfg.headers, psi.json_encode(body))
    if handle == nil then
      io.stderr:write(cfg.provider_name .. ": " .. tostring(begin_err) .. "\n")
      return false, "error"
    end

    while true do
      if abort_check() then break end
      local chunk, done = sched.http_poll(handle, 50)
      if chunk ~= nil then
        if raw_body_len < RAW_BODY_MAX then
          raw_body[#raw_body + 1] = chunk
          raw_body_len = raw_body_len + #chunk
        end
        cfg.parser_push(parser, chunk, state, observer)
      end
      if done then break end
    end
    local status = psi.http_stream_finish(handle)

    local tool_calls = cfg.finalize_tool_calls(state)

    if status < 0 then
      local aborted = abort_check()
      local reason = aborted and "aborted" or "error"
      local emsg = aborted and "Request was aborted" or "http transport error"
      if state.text ~= "" or #tool_calls > 0 then
        M.persist_assistant(state, model, tool_calls, cfg, reason, emsg)
        context.record_usage(psi.session_message_count(), state.usage, model)
        session_mod.save()
      end
      if not aborted then
        io.stderr:write(cfg.provider_name .. ": " .. emsg .. "\n")
      end
      return false, reason
    end
    if status < 200 or status >= 300 then
      local emsg = M.classify_http_error(
        status, table.concat(raw_body), cfg.provider_name)
      if state.text ~= "" or #tool_calls > 0 then
        M.persist_assistant(state, model, tool_calls, cfg, "error", emsg)
      end
      io.stderr:write(emsg .. "\n")
      -- Return the detailed emsg as the reply so the TUI's
      -- psi_tui_run_turn_sync can render it instead of a generic
      -- "provider request failed" banner. The first return is still
      -- false for control-flow callers; they already ignore the
      -- second value on failure.
      return false, emsg
    end

    M.persist_assistant(state, model, tool_calls, cfg)
    context.record_usage(psi.session_message_count(), state.usage, model)
    session_mod.save()

    if psi.events then
      local evt = {
        usage = state.usage,
        stop_reason = state.stop_reason,
        model = model,
      }
      if cfg.include_response_id then evt.response_id = state.response_id end
      psi.events.emit("after-provider-response", evt)
    end

    if #tool_calls == 0 then
      if psi.events then
        psi.events.emit("turn-end", { text = state.text, model = model })
      end
      return true, state.text
    end

    -- Concurrent tool dispatch (sched.run_all) — shared across
    -- every provider that uses this skeleton.
    if abort_check() then return false, "aborted" end

    for _, tc in ipairs(tool_calls) do
      local input_json = psi.json_encode(tc.arguments)
      if observer.on_tool_call then
        observer.on_tool_call(tc.id, tc.name, input_json)
      end
      if psi.events then
        psi.events.emit("tool-call",
          { id = tc.id, tool = tc.name, input = tc.arguments })
      end
    end

    local tasks = {}
    for i, tc in ipairs(tool_calls) do
      tasks[i] = function()
        return psi.tools.dispatch_alist(tc.name, tc.arguments,
                                        { tool_call_id = tc.id })
      end
    end
    local results = sched.run_all(tasks)

    for i, tc in ipairs(tool_calls) do
      local r = results[i]
      local result_alist
      if r.ok and r.values and r.values.n > 0 then
        result_alist = r.values[1]
      else
        result_alist = {
          tool = tc.name, ok = false,
          error = tostring(r and r.error or "tool dispatch failed"),
        }
      end
      local result_json = psi.json_encode(result_alist)
      if observer.on_tool_result then
        observer.on_tool_result(tc.id, tc.name, result_json)
      end
      if psi.events then
        psi.events.emit("tool-result",
          { id = tc.id, tool = tc.name, result = result_alist })
      end
      session_mod.append_tool_result(tc.id, tc.name, result_json,
                                     not result_alist.ok)
    end
    session_mod.save()
  end

  io.stderr:write(
    cfg.provider_name .. " tool loop exceeded "
    .. tostring(MAX_TOOL_ITERATIONS) .. " iterations\n")
  return false
end

-- ---------- Non-streaming one-shot completion ----------

function M.complete_text(opts, cfg)
  local body = cfg.request_body({
    model = opts.model or "",
    messages = prelude.as_array({
      { role = "system", content = opts.system_prompt or "" },
      { role = "user",   content = opts.user_text or "" },
    }),
    tool_specs = prelude.as_array({}),
    max_tokens = opts.max_tokens,
  })
  body.stream = false
  body.tools = nil
  body.stream_options = nil

  local status, response = psi.http_post(cfg.url, cfg.headers,
                                         psi.json_encode(body))
  if status == nil then
    io.stderr:write(cfg.provider_name .. ": http post failed: "
                    .. tostring(response) .. "\n")
    return false
  end
  if status < 200 or status >= 300 then
    io.stderr:write(("%s: request failed (%d): %s\n"):format(
      cfg.provider_name, status, response or ""))
    return false
  end

  local parsed = safe_decode(response)
  if type(parsed) ~= "table" then return false end
  return true, cfg.extract_completion(parsed)
end

return M
