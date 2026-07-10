-- psi.provider_loop: provider-neutral streaming tool loop.
--
-- Providers supply request/parse/persist callbacks. This module owns
-- run-loop behavior: steering/follow-up queues, context hooks,
-- HTTP polling, provider lifecycle events, concurrent tool dispatch,
-- persistence sequencing, and terminate=true handling.

local context = require("psi.context")
local control = require("psi.agent_control")
local prelude = require("psi.prelude")
local transform = require("psi.transform_messages")
local session_mod = require("psi.session_manager")

local M = {}

local RAW_BODY_MAX = 16 * 1024
local DEFAULT_MAX_RETRIES = 2
local DEFAULT_INITIAL_RETRY_DELAY_MS = 1000
local DEFAULT_MAX_RETRY_DELAY_MS = 60000
local RETRY_SLEEP_SLICE_MS = 100

local function nonnegative_integer(value, fallback)
  local n = tonumber(value)
  if n == nil or n < 0 then
    return fallback
  end
  return math.floor(n)
end

local function retry_settings(opts)
  local max_retries = opts.max_retries or opts.maxRetries or os.getenv("PSI_HTTP_MAX_RETRIES")
  local initial_delay = opts.retry_delay_ms
    or opts.initial_retry_delay_ms
    or os.getenv("PSI_HTTP_RETRY_DELAY_MS")
  local max_delay = opts.max_retry_delay_ms
    or opts.maxRetryDelayMs
    or os.getenv("PSI_HTTP_MAX_RETRY_DELAY_MS")
  return {
    max_retries = nonnegative_integer(max_retries, DEFAULT_MAX_RETRIES),
    initial_delay_ms = nonnegative_integer(initial_delay, DEFAULT_INITIAL_RETRY_DELAY_MS),
    max_delay_ms = nonnegative_integer(max_delay, DEFAULT_MAX_RETRY_DELAY_MS),
  }
end

local function terminal_rate_limit(body)
  if type(body) ~= "string" then
    return false
  end
  local text = body:lower()
  return text:find("usage limit", 1, true) ~= nil
    or text:find("insufficient_quota", 1, true) ~= nil
    or text:find("out of budget", 1, true) ~= nil
    or text:find("quota exceeded", 1, true) ~= nil
    or text:find("billing", 1, true) ~= nil
end

local function retryable_http_failure(status, body)
  if status == 429 and terminal_rate_limit(body) then
    return false
  end
  if
    status == 429
    or status == 500
    or status == 502
    or status == 503
    or status == 504
    or status == 529
  then
    return true
  end
  if type(body) == "string" then
    local text = body:lower()
    return text:find("rate limit") ~= nil
      or text:find("overloaded") ~= nil
      or text:find("service unavailable") ~= nil
      or text:find("upstream connect") ~= nil
      or text:find("connection refused") ~= nil
  end
  return false
end

local function retry_delay_ms(settings, attempt)
  local delay = settings.initial_delay_ms
  for _ = 1, attempt do
    delay = delay * 2
    if delay >= settings.max_delay_ms then
      return settings.max_delay_ms
    end
  end
  if delay > settings.max_delay_ms then
    return settings.max_delay_ms
  end
  return delay
end

local function sleep_for_retry(sched, delay_ms, abort_check)
  local remaining = delay_ms
  while remaining > 0 do
    if abort_check() then
      return false
    end
    local step = remaining
    if step > RETRY_SLEEP_SLICE_MS then
      step = RETRY_SLEEP_SLICE_MS
    end
    sched.sleep_ms(step)
    remaining = remaining - step
  end
  return not abort_check()
end

local function emit_context(cfg, model, system_prompt, messages)
  if psi.events then
    psi.events.emit("context", {
      messages = messages,
      model = model,
      provider = cfg.provider_name,
      system_prompt = system_prompt,
    })
  end
end

local function emit_before_request(cfg, model, body)
  if psi.events then
    psi.events.emit("before-provider-request", {
      provider = cfg.provider_name,
      model = model,
      body = body,
    })
  end
end

local function emit_after_response(cfg, state, model)
  if not psi.events then
    return
  end
  local evt = {
    usage = state.usage,
    stop_reason = state.stop_reason,
    model = model,
  }
  if cfg.response_id then
    evt.response_id = cfg.response_id(state)
  elseif cfg.include_response_id then
    evt.response_id = state.response_id
  end
  psi.events.emit("after-provider-response", evt)
end

local function emit_turn_end(text, model)
  if psi.events then
    psi.events.emit("turn-end", { text = text, model = model })
  end
end

local function queued_user_observer(observer, kind)
  return function(text)
    if observer.on_queued_user then
      observer.on_queued_user(text, kind)
    end
  end
end

local function append_queued_steering(observer)
  return control.append_steering(queued_user_observer(observer, "steering"))
end

local function append_queued_follow_ups(observer)
  return control.append_follow_ups(queued_user_observer(observer, "follow-up"))
end

local function normalize_tool_result(tc, r)
  if r and r.ok and r.values and r.values.n > 0 then
    return r.values[1]
  end
  return {
    tool = tc.name,
    ok = false,
    error = tostring(r and r.error or "tool dispatch failed"),
  }
end

local function tool_execution_mode(name)
  if not (psi.tools and psi.tools.find) then
    return "parallel"
  end
  local tool = psi.tools.find(name)
  if type(tool) == "table" and tool.execution_mode == "sequential" then
    return "sequential"
  end
  return "parallel"
end

local function dispatch_tools(tool_calls, observer, abort_check, cfg, model)
  local sched = require("psi.sched")
  if abort_check() then
    return nil, "aborted"
  end

  for _, tc in ipairs(tool_calls) do
    local input_json = psi.json_encode(tc.arguments or tc.input or {})
    if observer.on_tool_call then
      observer.on_tool_call(tc.id, tc.name, input_json)
    end
    if psi.events then
      psi.events.emit(
        "tool-call",
        { id = tc.id, tool = tc.name, input = tc.arguments or tc.input or {} }
      )
    end
  end

  local observed = {}
  local results = {}
  local function observe_done(i, r)
    local tc = tool_calls[i]
    if tc == nil then
      return
    end
    local result_alist = normalize_tool_result(tc, r)
    local result_json = psi.json_encode(result_alist)
    observed[i] = true
    if observer.on_tool_result then
      observer.on_tool_result(tc.id, tc.name, result_json)
    end
    if psi.events then
      psi.events.emit("tool-result", { id = tc.id, tool = tc.name, result = result_alist })
    end
  end

  local cursor = 1
  while cursor <= #tool_calls do
    if abort_check() then
      return nil, "aborted"
    end
    if tool_execution_mode(tool_calls[cursor].name) == "sequential" then
      local tc = tool_calls[cursor]
      local ok, value = pcall(function()
        return psi.tools.dispatch_alist(
          tc.name,
          tc.arguments or tc.input or {},
          { tool_call_id = tc.id, provider = cfg.provider_name, model = model }
        )
      end)
      local r
      if ok then
        r = { ok = true, values = { value, n = 1 } }
      else
        r = { ok = false, error = value }
      end
      results[cursor] = r
      observe_done(cursor, r)
      cursor = cursor + 1
    else
      local start = cursor
      local tasks = prelude.array(#tool_calls - cursor + 1)
      while
        cursor <= #tool_calls and tool_execution_mode(tool_calls[cursor].name) ~= "sequential"
      do
        local idx = cursor
        local tc = tool_calls[idx]
        tasks[#tasks + 1] = function()
          return psi.tools.dispatch_alist(
            tc.name,
            tc.arguments or tc.input or {},
            { tool_call_id = tc.id, provider = cfg.provider_name, model = model }
          )
        end
        cursor = cursor + 1
      end
      local batch = sched.run_all(tasks, {
        on_done = function(batch_index, r)
          observe_done(start + batch_index - 1, r)
        end,
        abort_check = abort_check,
      })
      for j, r in ipairs(batch) do
        results[start + j - 1] = r
      end
      if abort_check() then
        -- Don't append results to the session or send them to the
        -- LLM. The caller (run_turn) sees "aborted" on the next pass.
        return nil, "aborted"
      end
    end
  end

  for i, tc in ipairs(tool_calls) do
    local r = results[i]
    local result_alist = normalize_tool_result(tc, r)
    local result_json = psi.json_encode(result_alist)
    if (not observed[i]) and observer.on_tool_result then
      observer.on_tool_result(tc.id, tc.name, result_json)
    end
    if (not observed[i]) and psi.events then
      psi.events.emit("tool-result", { id = tc.id, tool = tc.name, result = result_alist })
    end
    session_mod.append_tool_result(
      tc.id,
      tc.name,
      result_json,
      not result_alist.ok,
      result_alist.content
    )
  end
  session_mod.save()
  return results
end

function M.run_turn(opts, cfg)
  local observer = opts.observer or {}
  local model = opts.model or ""
  local system_prompt = opts.system_prompt or ""
  local tool_specs = opts.tool_specs or cfg.tool_specs("")
  local abort_check = opts.abort_check or function()
    return false
  end
  local sched = require("psi.sched")
  local retries = retry_settings(opts)
  local has_partial = cfg.has_partial
    or function(state, tool_calls)
      return cfg.text(state) ~= "" or #tool_calls > 0
    end

  while true do
    if abort_check() then
      return false, "aborted"
    end
    append_queued_steering(observer)

    local api_messages = cfg.build_messages(transform.plain_session(), system_prompt, cfg, model)
    emit_context(cfg, model, system_prompt, api_messages)

    local request = cfg.request_body({
      model = model,
      messages = api_messages,
      tool_specs = tool_specs,
      max_tokens = opts.max_tokens,
      thinking_level = opts.thinking_level,
      reasoning_effort = opts.reasoning_effort,
      system_prompt = system_prompt,
    })
    emit_before_request(cfg, model, request)

    local state
    local raw_body
    local status
    local transport_error
    local content
    local tool_calls
    local stream_error
    local attempt = 0
    local request_json = psi.json_encode(request)

    while true do
      local parser
      local raw_body_len = 0
      local handle, begin_err

      state = cfg.new_state()
      parser = cfg.parser_new()
      raw_body = {}
      handle, begin_err = psi.http_stream_begin(cfg.url, cfg.headers, request_json)
      if handle == nil then
        local emsg = "http request failed: " .. tostring(begin_err)
        if cfg.save_failed_partial then
          cfg.save_failed_partial(state, model, "error", emsg)
        end
        io.stderr:write(cfg.provider_name .. ": " .. emsg .. "\n")
        return false, emsg
      end

      while true do
        if abort_check() then
          break
        end
        local chunk, done = sched.http_poll(handle, 50)
        if chunk ~= nil then
          if raw_body_len < RAW_BODY_MAX then
            raw_body[#raw_body + 1] = chunk
            raw_body_len = raw_body_len + #chunk
          end
          cfg.parser_push(parser, chunk, state, observer)
        end
        if done then
          break
        end
      end
      status, transport_error = psi.http_stream_finish(handle)
      content, tool_calls = cfg.finalize(state)
      stream_error = cfg.stream_error and cfg.stream_error(state)

      local body_text = table.concat(raw_body)
      local aborted = abort_check()
      local partial = has_partial(state, tool_calls)
      local retryable = not aborted
        and not partial
        and stream_error == nil
        and attempt < retries.max_retries
        and (status < 0 or retryable_http_failure(status, body_text))

      if not retryable then
        break
      end

      attempt = attempt + 1
      if not sleep_for_retry(sched, retry_delay_ms(retries, attempt - 1), abort_check) then
        break
      end
    end

    if status < 0 then
      local aborted = abort_check()
      local reason = aborted and "aborted" or "error"
      local emsg = aborted and "Request was aborted"
        or ("http transport error: " .. tostring(transport_error or "unknown error"))
      if cfg.save_failed_partial then
        cfg.save_failed_partial(state, model, reason, emsg)
      elseif has_partial(state, tool_calls) then
        cfg.persist(state, model, content, tool_calls, reason, emsg)
        context.record_usage(psi.session_message_count(), state.usage, model)
        session_mod.save()
      end
      if not aborted then
        io.stderr:write(cfg.provider_name .. ": " .. emsg .. "\n")
      end
      return false, aborted and reason or emsg
    end

    if status < 200 or status >= 300 then
      local emsg = cfg.classify_http_error(status, table.concat(raw_body), cfg.provider_name)
      if cfg.save_failed_partial then
        cfg.save_failed_partial(state, model, "error", emsg)
      elseif has_partial(state, tool_calls) then
        cfg.persist(state, model, content, tool_calls, "error", emsg)
      end
      io.stderr:write(emsg .. "\n")
      return false, emsg
    end

    if stream_error then
      cfg.persist(state, model, content, tool_calls, "error", stream_error)
      context.record_usage(psi.session_message_count(), state.usage, model)
      session_mod.save()
      io.stderr:write(stream_error .. "\n")
      return false, stream_error
    end

    cfg.persist(state, model, content, tool_calls)
    context.record_usage(psi.session_message_count(), state.usage, model)
    session_mod.save()
    emit_after_response(cfg, state, model)

    local text = cfg.text(state)
    if #tool_calls == 0 then
      cfg.after_iteration(model, opts)
      if append_queued_steering(observer) == 0 and append_queued_follow_ups(observer) == 0 then
        emit_turn_end(text, model)
        return true, text
      end
    else
      local results, err = dispatch_tools(tool_calls, observer, abort_check, cfg, model)
      if not results then
        return false, err
      end
      cfg.after_iteration(model, opts)
      if transform.all_results_terminate(results) then
        if append_queued_steering(observer) == 0 and append_queued_follow_ups(observer) == 0 then
          emit_turn_end(text, model)
          return true, text
        end
      end
    end
  end
end

return M
