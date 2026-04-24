-- psi.ollama: Ollama provider — same contract as psi.anthropic.
--
-- Entry points:
--   M.run_turn(opts)      — streaming tool-dispatch loop against
--                           Ollama's native POST /api/chat (NDJSON).
--   M.complete_text(opts) — non-streaming one-shot completion.
--
-- Same opts shape as psi.anthropic: system_prompt, model, max_tokens,
-- tool_specs, observer, abort_check, user_text (complete_text only).
--
-- Persistence uses the same pi-aligned v2 session shape so a session
-- started with one provider can be resumed with the other, as long as
-- tool names line up.

local context = require("psi.context")
local prelude = require("psi.prelude")
local tools = require("psi.tools")
local session_mod = require("psi.session")

local M = {}

local MODEL_ENV = "PSI_OLLAMA_MODEL"
local MODEL_DEFAULT = "llama3.1:latest"
local BASE_URL_ENV = "PSI_OLLAMA_BASE_URL"
local BASE_URL_DEFAULT = "http://localhost:11434/"
local MAX_TOOL_ITERATIONS = 32

local function api_url(path)
  local base = os.getenv(BASE_URL_ENV) or BASE_URL_DEFAULT
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  return base .. path
end

local function ollama_headers()
  return { "content-type: application/json" }
end

local function resolve_model(m)
  if m and m ~= "" then return m end
  return os.getenv(MODEL_ENV) or MODEL_DEFAULT
end

local safe_decode = prelude.safe_json_decode

-- Ollama accepts OpenAI-style tool specs: {type="function",
-- function={name, description, parameters=<json-schema>}}.
local function api_tool_specs(user_text)
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

-- ---------- Session -> Ollama messages ----------
--
-- Ollama's /api/chat is chronological; each session entry maps 1:1
-- (no coalescing needed). Aborted/error assistants are skipped like
-- pi's transform-messages. Orphan tool_use blocks get a synthetic
-- tool-role message with "No result provided" just before the next
-- user turn, matching the Anthropic-side behavior in build_api_messages.
local function build_api_messages(session, system_prompt)
  local out = {}
  if system_prompt and system_prompt ~= "" then
    out[#out + 1] = { role = "system", content = system_prompt }
  end

  local pending_tool_calls = {}
  local seen_result_ids = {}

  local function flush_synthetic_results()
    for _, tc in ipairs(pending_tool_calls) do
      if not seen_result_ids[tc.id] then
        out[#out + 1] = {
          role = "tool",
          content = "No result provided",
          tool_name = tc.name,
        }
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
              tool_calls[#tool_calls + 1] = {
                id = b.id,
                ["function"] = { name = b.name, arguments = b.arguments or {} },
              }
            end
          end
        end
        local entry = { role = "assistant", content = text }
        if tool_calls then entry.tool_calls = tool_calls end
        out[#out + 1] = entry

        pending_tool_calls = {}
        seen_result_ids = {}
        if tool_calls then
          for _, tc in ipairs(tool_calls) do
            pending_tool_calls[#pending_tool_calls + 1] = { id = tc.id, name = tc["function"].name }
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
          out[#out + 1] = {
            role = "tool",
            content = text,
            tool_name = tm.toolName or "",
          }
          if tid ~= "" then seen_result_ids[tid] = true end
        end
        i = i + 1
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

-- ---------- NDJSON streaming parser ----------
--
-- Ollama streams one JSON object per newline-terminated line. The
-- `done=true` object carries usage totals (prompt_eval_count and
-- eval_count). Tool calls arrive as complete objects in a single
-- message (no delta streaming), so we don't need a blockwise state
-- machine like Anthropic.
local function new_state()
  return {
    text = "",
    tool_calls = {}, -- array of {id, name, arguments_table}
    usage = nil,
    done = false,
  }
end

local function handle_line(line, state, observer)
  local obj = safe_decode(line)
  if type(obj) ~= "table" then return end
  local msg = obj.message
  if type(msg) == "table" then
    if type(msg.content) == "string" and msg.content ~= "" then
      state.text = state.text .. msg.content
      if observer.on_assistant_text_delta then
        observer.on_assistant_text_delta(msg.content)
      end
      if psi.events then psi.events.emit("assistant-text-delta", {text = msg.content}) end
    end
    if type(msg.tool_calls) == "table" then
      for _, tc in ipairs(msg.tool_calls) do
        local fn = tc["function"] or {}
        local args = fn.arguments or {}
        -- Ollama passes arguments as a parsed object, not a JSON string.
        if type(args) == "string" then
          args = prelude.safe_json_decode(args, {})
        end
        local id = tc.id
        if not id or id == "" then
          -- Synthesize for older Ollama builds that omit tool_call ids.
          id = "call_" .. prelude.uuid_short():sub(1, 12)
        end
        state.tool_calls[#state.tool_calls + 1] = {
          id = id, name = fn.name or "", arguments = args,
        }
      end
    end
  end
  if obj.done then
    state.done = true
    state.usage = {
      prompt_tokens = obj.prompt_eval_count or 0,
      completion_tokens = obj.eval_count or 0,
      total_duration_ns = obj.total_duration or 0,
    }
    state.stop_reason = obj.done_reason or "stop"
  end
end

-- Stateful NDJSON parser. Same rationale as the Anthropic SSE parser
-- over in psi/anthropic.lua: accumulate the current in-flight line
-- as a table, concat once per `\n`, never hold a cross-chunk
-- "leftover" string. Ollama streams are line-delimited JSON; each
-- complete line is one event.
local function new_ndjson_parser()
  return { line = {} }
end

local function ndjson_push(parser, chunk, state, observer)
  local start = 1
  local len = #chunk
  while start <= len do
    local nl = chunk:find("\n", start, true)
    if not nl then
      parser.line[#parser.line + 1] = chunk:sub(start)
      break
    end
    parser.line[#parser.line + 1] = chunk:sub(start, nl - 1)
    local line = table.concat(parser.line)
    parser.line = {}
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if #line > 0 then handle_line(line, state, observer) end
    start = nl + 1
  end
end

-- ---------- Append Ollama results into the session (pi shape) ----------
--
-- The session format is provider-neutral; we just translate tool_calls
-- to the pi `tool_use`-flavored Anthropic-style blocks that
-- session.append_assistant expects.
local function persist_assistant(state, model, stop_override, error_message)
  local blocks = {}
  if state.text ~= "" then
    blocks[#blocks + 1] = { type = "text", text = state.text }
  end
  for _, tc in ipairs(state.tool_calls) do
    blocks[#blocks + 1] = {
      type = "tool_use", id = tc.id, name = tc.name, input = tc.arguments,
    }
  end
  -- Ollama usage -> pi normalized form via the anthropic-verbose keys so
  -- normalize_usage in session.lua can handle it uniformly.
  local usage
  if state.usage then
    usage = {
      input_tokens = state.usage.prompt_tokens or 0,
      output_tokens = state.usage.completion_tokens or 0,
    }
  end
  session_mod.append_assistant(state.text, blocks, {
    usage = usage,
    stop_reason = stop_override or state.stop_reason,
    error_message = error_message,
    model = model,
    provider = "ollama",
    api = "ollama-chat",
  })
end

-- ---------- One-shot completion ----------

function M.complete_text(opts)
  local url = api_url("api/chat")
  local request = {
    model = resolve_model(opts.model),
    stream = false,
    options = {},
    messages = prelude.as_array({
      {role = "system", content = opts.system_prompt or ""},
      {role = "user",   content = opts.user_text or ""},
    }),
  }
  if opts.max_tokens then
    request.options.num_predict = opts.max_tokens
  end
  local status, body = psi.http_post(url, ollama_headers(), psi.json_encode(request))
  if status == nil then
    io.stderr:write("ollama: http post failed: " .. tostring(body) .. "\n")
    return false
  end
  if status < 200 or status >= 300 then
    io.stderr:write("ollama: request failed (" .. tostring(status) .. "): " .. (body or "") .. "\n")
    return false
  end
  local parsed = safe_decode(body)
  if type(parsed) ~= "table" or type(parsed.message) ~= "table" then return false end
  return true, parsed.message.content or ""
end

-- ---------- Streaming agent turn ----------

function M.run_turn(opts)
  local observer = opts.observer or {}
  local model = resolve_model(opts.model)
  local system_prompt = opts.system_prompt or ""
  local tool_specs = opts.tool_specs or api_tool_specs("")
  local abort_check = opts.abort_check or function() return false end

  local headers = ollama_headers()
  local url = api_url("api/chat")

  for _ = 1, MAX_TOOL_ITERATIONS do
    if abort_check() then return false, "aborted" end

    local session_messages = require("psi.session").messages()
    local plain = {}
    for i, m in ipairs(session_messages) do
      plain[i] = { role = m.role, text = m.text, data = m.data }
    end
    local api_messages = build_api_messages(plain, system_prompt)

    local request = {
      model = model,
      messages = api_messages,
      tools = tool_specs,
      stream = true,
      options = {},
    }
    if opts.max_tokens then request.options.num_predict = opts.max_tokens end

    local state = new_state()
    local parser = new_ndjson_parser()
    local sched = require("psi.sched")

    local handle, begin_err = psi.http_stream_begin(url, headers, psi.json_encode(request))
    if handle == nil then
      io.stderr:write("ollama: " .. tostring(begin_err) .. "\n")
      return false, "error"
    end

    while true do
      if abort_check() then break end
      local chunk, done = sched.http_poll(handle, 50)
      if chunk ~= nil then
        ndjson_push(parser, chunk, state, observer)
      end
      if done then break end
    end
    local status = psi.http_stream_finish(handle)

    if status < 0 then
      local aborted = abort_check()
      local reason = aborted and "aborted" or "error"
      local emsg = aborted and "Request was aborted" or "http transport error"
      if state.text ~= "" or #state.tool_calls > 0 then
        persist_assistant(state, model, reason, emsg)
        context.record_usage(psi.session_message_count(),
          state.usage and {
            input_tokens = state.usage.prompt_tokens,
            output_tokens = state.usage.completion_tokens,
          } or nil,
          model)
        session_mod.save()
      end
      if not aborted then io.stderr:write("ollama: " .. emsg .. "\n") end
      return false, reason
    end
    if status < 200 or status >= 300 then
      local emsg = string.format("ollama request failed (%d)", status)
      if state.text ~= "" or #state.tool_calls > 0 then
        persist_assistant(state, model, "error", emsg)
      end
      io.stderr:write(emsg .. "\n")
      return false, "error"
    end

    persist_assistant(state, model)
    context.record_usage(psi.session_message_count(),
      state.usage and {
        input_tokens = state.usage.prompt_tokens,
        output_tokens = state.usage.completion_tokens,
      } or nil,
      model)
    session_mod.save()

    if psi.events then
      psi.events.emit("after-provider-response", {
        usage = state.usage,
        stop_reason = state.stop_reason,
        model = model,
      })
    end

    if #state.tool_calls == 0 then
      if psi.events then
        psi.events.emit("turn-end", { text = state.text, model = model })
      end
      return true, state.text
    end

    -- Concurrent tool dispatch. Mirrors psi.anthropic: all
    -- tool_calls emitted in one model response run through
    -- sched.run_all so their wall time is ~max(times) rather
    -- than the sum.
    if abort_check() then return false, "aborted" end

    for _, tc in ipairs(state.tool_calls) do
      local input_json = psi.json_encode(tc.arguments)
      if observer.on_tool_call then observer.on_tool_call(tc.id, tc.name, input_json) end
      if psi.events then
        psi.events.emit("tool-call", { id = tc.id, tool = tc.name, input = tc.arguments })
      end
    end

    local tasks = {}
    for i, tc in ipairs(state.tool_calls) do
      tasks[i] = function()
        return psi.tools.dispatch_alist(tc.name, tc.arguments,
                                        { tool_call_id = tc.id })
      end
    end
    local results = require("psi.sched").run_all(tasks)

    for i, tc in ipairs(state.tool_calls) do
      local r = results[i]
      local result_alist
      if r.ok and r.values and r.values.n > 0 then
        result_alist = r.values[1]
      else
        result_alist = {
          tool = tc.name,
          ok = false,
          error = tostring(r and r.error or "tool dispatch failed"),
        }
      end
      local result_json = psi.json_encode(result_alist)
      if observer.on_tool_result then observer.on_tool_result(tc.id, tc.name, result_json) end
      if psi.events then
        psi.events.emit("tool-result", { id = tc.id, tool = tc.name, result = result_alist })
      end
      session_mod.append_tool_result(tc.id, tc.name, result_json, not result_alist.ok)
    end
    session_mod.save()
  end

  io.stderr:write("ollama tool loop exceeded " .. tostring(MAX_TOOL_ITERATIONS) .. " iterations\n")
  return false
end

return M
