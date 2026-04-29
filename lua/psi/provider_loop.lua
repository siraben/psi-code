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
  return function(text, _, images)
    if observer.on_queued_user then
      observer.on_queued_user(text, kind, images)
    end
  end
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

local function dispatch_tools(tool_calls, observer, abort_check)
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
    if tool_execution_mode(tool_calls[cursor].name) == "sequential" then
      local tc = tool_calls[cursor]
      local ok, value = pcall(function()
        return psi.tools.dispatch_alist(
          tc.name,
          tc.arguments or tc.input or {},
          { tool_call_id = tc.id }
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
            { tool_call_id = tc.id }
          )
        end
        cursor = cursor + 1
      end
      local batch = sched.run_all(tasks, {
        on_done = function(batch_index, r)
          observe_done(start + batch_index - 1, r)
        end,
      })
      for j, r in ipairs(batch) do
        results[start + j - 1] = r
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
    session_mod.append_tool_result(tc.id, tc.name, result_json, not result_alist.ok)
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

  while true do
    if abort_check() then
      return false, "aborted"
    end
    control.append_steering(queued_user_observer(observer, "steering"))

    local api_messages = cfg.build_messages(transform.plain_session(), system_prompt, cfg)
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

    local state = cfg.new_state()
    local parser = cfg.parser_new()
    local raw_body = {}
    local raw_body_len = 0
    local handle, begin_err = psi.http_stream_begin(cfg.url, cfg.headers, psi.json_encode(request))
    if handle == nil then
      if cfg.save_failed_partial then
        cfg.save_failed_partial(state, model, "error", tostring(begin_err))
      end
      io.stderr:write(cfg.provider_name .. ": " .. tostring(begin_err) .. "\n")
      return false, "error"
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
    local status, transport_error = psi.http_stream_finish(handle)
    local content, tool_calls = cfg.finalize(state)
    local stream_error = cfg.stream_error and cfg.stream_error(state)

    if status < 0 then
      local aborted = abort_check()
      local reason = aborted and "aborted" or "error"
      local emsg = aborted and "Request was aborted"
        or ("http transport error: " .. tostring(transport_error or "unknown error"))
      if cfg.save_failed_partial then
        cfg.save_failed_partial(state, model, reason, emsg)
      elseif cfg.has_partial(state, tool_calls) then
        cfg.persist(state, model, content, tool_calls, reason, emsg)
        context.record_usage(psi.session_message_count(), state.usage, model)
        session_mod.save()
      end
      if not aborted then
        io.stderr:write(cfg.provider_name .. ": " .. emsg .. "\n")
      end
      return false, reason
    end

    if status < 200 or status >= 300 then
      local emsg = cfg.classify_http_error(status, table.concat(raw_body), cfg.provider_name)
      if cfg.save_failed_partial then
        cfg.save_failed_partial(state, model, "error", emsg)
      elseif cfg.has_partial(state, tool_calls) then
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
      if control.append_follow_ups(queued_user_observer(observer, "follow-up")) == 0 then
        emit_turn_end(text, model)
        return true, text
      end
    else
      local results, err = dispatch_tools(tool_calls, observer, abort_check)
      if not results then
        return false, err
      end
      cfg.after_iteration(model, opts)
      if transform.all_results_terminate(results) then
        if control.append_follow_ups(queued_user_observer(observer, "follow-up")) == 0 then
          emit_turn_end(text, model)
          return true, text
        end
      end
    end
  end
end

return M
