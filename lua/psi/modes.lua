-- psi.modes: top-level runtime mode implementations.
--
-- Each mode used to live as its own C function in src/runtime/print_mode.c.
-- The C host now only inits the VM + session and delegates here; this
-- module owns the session lifecycle, REPL loop, observer wiring, and
-- command dispatch.

local agent = require("psi.agent_session")
local prelude = require("psi.prelude")
local prompt = require("psi.prompt")
local render = require("psi.render")
local session = require("psi.session_manager")

local M = {}

-- ---------- rendering helpers ----------

local function fire(event, payload)
  local text = render.handle_event(event, payload or {})
  if text ~= nil and text ~= "" then
    psi.stdout_write(text)
  end
end

local json_parse_or = prelude.safe_json_decode

local function choose_session_cli(infos)
  io.stderr:write("Select a session to resume:\n")
  for i, info in ipairs(infos) do
    io.stderr:write(string.format("  %d. %s\n", i, session.describe_session(info)))
    for _, line in ipairs(info.preview or {}) do
      io.stderr:write("     " .. line .. "\n")
    end
  end
  local line = psi.readline("session> ")
  local choice = tonumber(line or "")
  if choice and infos[choice] then
    return choice
  end
  return nil
end

local function bootstrap_session(opts)
  if opts.session_file and opts.session_file ~= "" then
    return session.load(opts.session_file)
  end
  if opts.resume then
    local selected, err = session.resolve_resume_path(psi.cwd(), choose_session_cli)
    if not selected then
      return false, err
    end
    opts.session_file = selected
    return session.load(selected)
  end
  local path = session.ensure_default_path()
  opts.session_autosave_optional = true
  if not path then
    session.announce_start()
    return true
  end
  session.announce_start()
  return true
end

local function save_current_session(opts)
  local ok, err = session.save()
  if not ok then
    if opts and opts.session_autosave_optional then
      return true
    end
    io.stderr:write("failed to save session file: " .. tostring(err) .. "\n")
    return false
  end
  return true
end

-- Build an observer whose callbacks stream rendered events to stdout.
local function print_observer()
  local state = { assistant_wrote_text = false }
  return state,
    {
      on_assistant_text_delta = function(text)
        fire("assistant-text", { text = text or "" })
        if text and text ~= "" then
          state.assistant_wrote_text = true
        end
      end,
      -- Route reasoning-model thinking through the render pipeline
      -- so REPL / --agent / --print callers can see it (boot.lua
      -- installs a default dim-prefixed renderer). Without this the
      -- thinking stream vanishes — models like qwen3 that emit
      -- everything in the thinking channel look like they returned
      -- nothing at all. The TUI has its own observer.thinking_delta
      -- path, so this only fires in non-TUI modes.
      on_thinking_delta = function(text)
        fire("thinking-delta", { text = text or "" })
      end,
      on_tool_call = function(id, name, input_json)
        fire(
          "tool-call",
          { id = id or "", tool = name or "", input = json_parse_or(input_json, {}) }
        )
      end,
      on_tool_result = function(id, name, output_json)
        local parsed = json_parse_or(output_json, nil)
        local result
        if parsed == nil then
          result = output_json and { raw = output_json } or {}
        else
          result = parsed
        end
        fire("tool-result", { id = id or "", tool = name or "", result = result })
      end,
    }
end

local function run_agent_turn(opts, user_text)
  local render_state, observer = print_observer()
  fire("before-turn", { text = user_text or "" })
  local ok, reply = agent.run_turn({
    user_text = user_text or "",
    model = opts.model,
    max_tokens = opts.max_tokens,
    thinking_level = opts.thinking_level,
    reasoning_effort = opts.reasoning_effort,
    observer = observer,
    abort_check = psi.is_aborted,
  })
  if not ok then
    return false, reply
  end
  fire("after-turn", {
    text = reply or "",
    ["assistant-streamed"] = render_state.assistant_wrote_text,
  })
  return true, reply
end

-- ---------- mode handlers ----------

function M.run_print(opts)
  local loaded, load_err = bootstrap_session(opts)
  if not loaded then
    io.stderr:write("failed to load session file: " .. tostring(load_err) .. "\n")
    return false
  end
  session.append_user(opts.payload or "")
  local reply = prompt.handle_print(opts.payload or "")
  session.append_assistant(reply, { { type = "text", text = reply } }, {})
  if not save_current_session(opts) then
    session.announce_shutdown()
    return false
  end
  session.announce_shutdown()
  print(reply)
  return true
end

function M.run_eval(opts)
  local ok, value = prelude.eval_expression(opts.payload or "")
  if not ok then
    io.stderr:write("eval error: " .. tostring(value) .. "\n")
    return false
  end
  if value == nil then
    print("nil")
  elseif type(value) == "string" then
    print(value)
  else
    print(tostring(value))
  end
  return true
end

function M.run_system_prompt(_opts)
  print(prompt.system_prompt())
  return true
end

function M.run_agent(opts)
  agent.configure(opts)
  local loaded, load_err = bootstrap_session(opts)
  if not loaded then
    io.stderr:write("failed to load session file: " .. tostring(load_err) .. "\n")
    return false
  end
  local ok = run_agent_turn(opts, opts.payload or "")
  if not ok then
    session.announce_shutdown()
    return false
  end
  if not save_current_session(opts) then
    session.announce_shutdown()
    return false
  end
  session.announce_shutdown()
  return true
end

function M.run_compact(opts)
  agent.configure(opts)
  if opts.resume and (not opts.session_file or opts.session_file == "") then
    local selected, err = session.resolve_resume_path(psi.cwd(), choose_session_cli)
    if not selected then
      io.stderr:write("--compact resume failed: " .. tostring(err) .. "\n")
      return false
    end
    opts.session_file = selected
  end
  if not opts.session_file or opts.session_file == "" then
    io.stderr:write("--compact requires --session FILE or --resume\n")
    return false
  end
  session.load(opts.session_file)
  local ok, summary = agent.run_compact({
    keep_recent = opts.keep_recent,
    model = opts.model,
    max_tokens = opts.max_tokens,
    thinking_level = opts.thinking_level,
    reasoning_effort = opts.reasoning_effort,
  })
  if not ok then
    io.stderr:write("failed to compact session\n")
    return false
  end
  local saved, err = session.save()
  if not saved then
    io.stderr:write("failed to save session file: " .. tostring(err) .. "\n")
    return false
  end
  print(summary or "")
  return true
end

-- REPL slash-command dispatcher.
--
-- Returns (continue, quit): continue=false aborts the REPL with an
-- error, quit=true ends the loop cleanly.
local function handle_slash_command(opts, line)
  local commands = require("psi.slash_commands")
  local action = commands.handle(line)
  if action == nil then
    io.stderr:write("unknown command\n")
    return true, false
  end
  local kind = action.kind
  if kind == "print" then
    print(action.payload or "")
    return true, false
  end
  if kind == "ansi-print" then
    print(action.payload or "")
    return true, false
  end
  if kind == "btw" then
    local question = tostring(action.payload or "")
    print("/btw " .. question)
    local ok, answer = agent.side_question(question, {
      model = opts.model,
      max_tokens = 1024,
      context_chars = 24000,
    })
    if not ok then
      print("btw failed: " .. tostring(answer))
    else
      print(answer or "")
    end
    return true, false
  end
  if kind == "quit" then
    return true, true
  end
  if kind == "compact" then
    local ok, summary = agent.run_compact({
      keep_recent = action.payload,
      model = opts.model,
      max_tokens = opts.max_tokens,
      thinking_level = opts.thinking_level,
      reasoning_effort = opts.reasoning_effort,
    })
    if not ok then
      io.stderr:write("failed to compact session\n")
      return false, false
    end
    if not save_current_session(opts) then
      return false, false
    end
    print("compaction summary:\n" .. (summary or ""))
    return true, false
  end
  if kind == "set-model" then
    opts.model = action.payload
    print("model set to " .. tostring(opts.model))
    return true, false
  end
  if kind == "set-reasoning-effort" then
    local value = action.payload
    opts.reasoning_effort = value
    opts.thinking_level = value == "none" and "off" or value
    agent.set_reasoning_effort(value)
    print("reasoning effort set to " .. tostring(value or "none"))
    return true, false
  end
  if kind == "set-thinking" then
    local ok, level = agent.set_thinking_level(action.payload, opts.model)
    if not ok then
      print(level)
      return true, false
    end
    opts.thinking_level = level
    opts.reasoning_effort = level == "off" and "none" or level
    print("thinking set to " .. tostring(level))
    return true, false
  end
  -- "new-session" / "reload" are now handled inside slash_commands.lua and
  -- come back as "print" actions; no REPL-specific arms needed.
  if kind == "resume" then
    local path = action.payload
    local ok, err = session.load(path)
    if not ok then
      io.stderr:write("resume failed: " .. tostring(err) .. "\n")
      return true, false
    end
    opts.session_file = path
    psi.context.reset_usage()
    print("resumed " .. path .. " (" .. tostring(psi.session_message_count()) .. " messages)")
    return true, false
  end
  if kind == "name" then
    session.set_display_name(action.payload)
    session.save()
    print("name set to '" .. tostring(action.payload) .. "'")
    return true, false
  end
  if kind == "expand" then
    -- Prompt-template expansion: treat the expanded body as a
    -- user turn. Print it so the user sees what the template
    -- actually sent (templates can be opaque for new users).
    print("> " .. (action.payload or ""))
    local ok = run_agent_turn(opts, action.payload or "")
    if ok and not save_current_session(opts) then
      return false, false
    end
    return true, false
  end
  io.stderr:write("unknown command\n")
  return true, false
end

function M.run_repl(opts)
  agent.configure(opts)
  local loaded, load_err = bootstrap_session(opts)
  if not loaded then
    io.stderr:write("failed to load session file: " .. tostring(load_err) .. "\n")
    return false
  end
  print("psi coding agent")
  while true do
    local line = psi.readline("psi> ")
    if line == nil then
      break
    end
    if line:sub(1, 1) == "/" then
      local ok, quit = handle_slash_command(opts, line)
      if not ok then
        return false
      end
      if quit then
        break
      end
    else
      if line ~= "" then
        psi.add_history(line)
      end
      local ok = run_agent_turn(opts, line)
      if ok then
        if not save_current_session(opts) then
          session.announce_shutdown()
          return false
        end
      end
    end
  end
  session.announce_shutdown()
  return true
end

function M.run_tui(opts)
  return require("psi.tui_runtime").run(opts)
end

-- ---------- dispatcher ----------

local DISPATCH = {
  print = M.run_print,
  eval = M.run_eval,
  ["system-prompt"] = M.run_system_prompt,
  agent = M.run_agent,
  compact = M.run_compact,
  repl = M.run_repl,
  tui = M.run_tui,
}

function M.run(opts)
  local fn = DISPATCH[opts.mode]
  if not fn then
    io.stderr:write("psi.modes.run: unknown mode '" .. tostring(opts.mode) .. "'\n")
    return false
  end
  return fn(opts) and true or false
end

return M
