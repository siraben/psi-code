-- psi.agent_runtime: shared lifecycle facade for runtime frontends.
--
-- agent_session owns provider/model state and agent operations. This module
-- owns the lifecycle around those operations: bootstrap/resume, observer
-- composition, persistence, session replacement, and shutdown. Frontends
-- supply only their picker and rendering callbacks.

local agent = require("psi.agent_session")
local context = require("psi.context")
local notice = require("psi.notice")
local session = require("psi.session_manager")
local traceback = debug.traceback

local M = {}
local Runtime = {}
Runtime.__index = Runtime

local function looks_like_session_id(value)
  if type(value) ~= "string" or value == "" then
    return false
  end
  if value:find("/", 1, true) or value:find("\\", 1, true) then
    return false
  end
  return value:sub(-6) ~= ".jsonl"
end

local function selected_path(selected, infos)
  if type(selected) == "number" then
    selected = infos[selected] and infos[selected].path or nil
  elseif type(selected) == "table" then
    selected = selected.path
  end
  if type(selected) ~= "string" or selected == "" then
    return nil, "no session selected"
  end
  return selected
end

local function copy_observer(observer)
  local copy = {}
  for key, value in pairs(observer or {}) do
    copy[key] = value
  end
  return copy
end

function M.new(opts)
  opts = opts or {}
  agent.configure(opts)
  return setmetatable({
    opts = opts,
    started = false,
    closed = false,
    autosave_optional = false,
  }, Runtime)
end

function Runtime:_resolve_session_file(value)
  if not looks_like_session_id(value) then
    return value
  end
  return session.find_session_by_id(value, psi.cwd())
end

function Runtime:_load(path)
  local existed = psi.file_exists(path)
  local ok, err = session.load(path)
  if not ok then
    return false, err
  end
  if not existed then
    session.announce_start()
  end
  self.started = true
  self.closed = false
  self.opts.session_file = path
  context.reset_usage()
  return true
end

function Runtime:_choose_resume(options)
  options = options or {}
  local choose = options.choose_session
  if options.always_choose then
    local infos = session.list_sessions(psi.cwd())
    if type(choose) ~= "function" then
      return nil, "session picker unavailable"
    end
    return selected_path(choose(infos), infos)
  end
  return session.resolve_resume_path(psi.cwd(), choose)
end

function Runtime:bootstrap(options)
  options = options or {}
  if self.started and not self.closed then
    return true
  end

  local path = self.opts.session_file
  if path and path ~= "" then
    local resolved, err = self:_resolve_session_file(path)
    if not resolved then
      return false, err
    end
    return self:_load(resolved)
  end

  if self.opts.continue_recent then
    path = session.most_recent_session(psi.cwd())
    if path then
      return self:_load(path)
    end
    if options.allow_new == false then
      return false, "no prior session for " .. tostring(psi.cwd())
    end
    if type(options.on_continue_missing) == "function" then
      options.on_continue_missing(psi.cwd())
    end
  end

  if self.opts.resume then
    local err
    path, err = self:_choose_resume(options)
    if not path then
      return false, err
    end
    return self:_load(path)
  end

  if options.allow_new == false then
    return false, "session file required"
  end

  path = session.ensure_default_path()
  if not path then
    if options.require_session_path then
      return false, "could not determine default session path"
    end
    self.autosave_optional = true
  end
  session.announce_start()
  self.started = true
  self.closed = false
  return true
end

function Runtime:save()
  local ok, err = session.save()
  if not ok and self.autosave_optional then
    return true
  end
  return ok, err
end

function Runtime:turn(user_text, options)
  options = options or {}
  local assistant_streamed = false
  local observer = copy_observer(options.observer)
  local on_text = observer.on_assistant_text_delta
  observer.on_assistant_text_delta = function(text)
    if type(text) == "string" and text ~= "" then
      assistant_streamed = true
    end
    if on_text then
      on_text(text)
    end
  end

  local text = user_text or ""
  if type(options.before_turn) == "function" then
    options.before_turn({ text = text })
  end

  local function turn_options()
    return {
      user_text = text,
      model = self.opts.model,
      max_tokens = self.opts.max_tokens,
      thinking_level = self.opts.thinking_level,
      reasoning_effort = self.opts.reasoning_effort,
      observer = observer,
      abort_check = options.abort_check or psi.is_aborted,
    }
  end

  local function auto_compact(reason, descriptor)
    local estimate = context.estimate_context_tokens()
    notice.info(
      string.format(
        "psi: auto-compacting (%s, context ~%d tokens, threshold %d)",
        reason,
        estimate.tokens,
        context.context_window(descriptor) - context.reserve_tokens()
      )
    )
    local compact_ok, compact_summary = agent.run_compact({
      model = self.opts.model,
      thinking_level = self.opts.thinking_level,
      reasoning_effort = self.opts.reasoning_effort,
      abort_check = options.abort_check or psi.is_aborted,
      reason = reason,
    })
    if not compact_ok then
      notice.error("psi: auto-compaction failed: " .. tostring(compact_summary))
      return false
    end
    session.save()
    return true
  end

  local ran, ok, reply = xpcall(function()
    local descriptor = agent.model_descriptor(self.opts.model)
    local over = context.should_compact(descriptor)
    if over then
      auto_compact("threshold", descriptor)
    end

    local turn_ok, turn_reply = agent.run_turn(turn_options())
    descriptor = agent.model_descriptor(self.opts.model)
    if
      not turn_ok
      and context.auto_compact_enabled()
      and context.is_overflow_error(tostring(turn_reply or ""))
      and auto_compact("overflow", descriptor)
    then
      local retry_options = turn_options()
      retry_options.user_text = nil
      turn_ok, turn_reply = agent.continue_turn(retry_options)
    end

    if turn_ok and context.auto_compact_enabled() then
      descriptor = agent.model_descriptor(self.opts.model)
      if context.usage_exceeds_window(descriptor) then
        auto_compact("overflow", descriptor)
      else
        local should = context.should_compact(descriptor)
        if should then
          auto_compact("threshold", descriptor)
        end
      end
    end
    return turn_ok, turn_reply
  end, traceback)

  local payload = {
    text = ran and (reply or "") or "",
    ["assistant-streamed"] = ran and assistant_streamed or false,
  }
  if type(options.after_turn) == "function" then
    options.after_turn(payload, ran and ok or false, ran)
  end

  local saved, save_err = self:save()
  if not ran then
    return false,
      reply,
      {
        assistant_streamed = false,
        save_ok = saved,
        save_error = save_err,
        crashed = true,
      }
  end
  return ok,
    reply,
    {
      assistant_streamed = assistant_streamed,
      save_ok = saved,
      save_error = save_err,
      crashed = false,
    }
end

function Runtime:compact(keep_recent, options)
  options = options or {}
  local ran, ok, summary = xpcall(function()
    return agent.run_compact({
      keep_recent = keep_recent,
      model = self.opts.model,
      max_tokens = self.opts.max_tokens,
      thinking_level = self.opts.thinking_level,
      reasoning_effort = self.opts.reasoning_effort,
      abort_check = options.abort_check or psi.is_aborted,
      reason = options.reason or "manual",
    })
  end, traceback)
  if not ran or not ok then
    return false, summary, { crashed = not ran }
  end
  local saved, save_err = self:save()
  return true, summary, {
    save_ok = saved,
    save_error = save_err,
    crashed = false,
  }
end

function Runtime:switch_session(path)
  local resolved, err = self:_resolve_session_file(path)
  if not resolved then
    return false, err
  end
  if self.started and not self.closed then
    session.announce_shutdown()
  end
  self.started = false
  self.closed = false
  local ok, load_err = self:_load(resolved)
  if not ok then
    return false, load_err
  end
  return true
end

function Runtime:shutdown()
  if not self.started or self.closed then
    return
  end
  self.closed = true
  session.announce_shutdown()
end

return M
