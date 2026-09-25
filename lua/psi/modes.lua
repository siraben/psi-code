-- psi.modes: top-level runtime mode implementations.
--
-- Each mode used to live as its own C function in src/runtime/print_mode.c.
-- The C host now only inits the VM + session and delegates here; this
-- module owns the REPL loop, rendering policy, and command dispatch.
-- Shared session lifecycle and observer composition live in
-- psi.agent_session_runtime.

local agent = require("psi.agent_session")
local agent_runtime = require("psi.agent_session_runtime")
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

local function bootstrap_runtime(opts, options)
  local runtime = agent_runtime.new(opts)
  options = options or {}
  options.choose_session = options.choose_session or choose_session_cli
  options.on_continue_missing = options.on_continue_missing
    or function(cwd)
      io.stderr:write(
        "--continue: no prior session for " .. tostring(cwd) .. ", starting a new one\n"
      )
    end
  local ok, err = runtime:bootstrap(options)
  return runtime, ok, err
end

-- Build an observer whose callbacks stream rendered events to stdout.
local PRINT_OBSERVER = {
  on_assistant_text_delta = function(text)
    fire("assistant-text", { text = text or "" })
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
    fire("tool-call", { id = id or "", tool = name or "", input = json_parse_or(input_json, {}) })
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

local function fire_before_turn(payload)
  fire("before-turn", payload)
end

local function fire_after_turn(payload)
  fire("after-turn", payload)
end

local function run_agent_turn(runtime, user_text)
  return runtime:turn(user_text, {
    observer = PRINT_OBSERVER,
    abort_check = psi.is_aborted,
    before_turn = fire_before_turn,
    after_turn = fire_after_turn,
  })
end

-- ---------- mode handlers ----------

function M.run_print(opts)
  local runtime, loaded, load_err = bootstrap_runtime(opts)
  if not loaded then
    io.stderr:write("failed to load session file: " .. tostring(load_err) .. "\n")
    return false
  end
  session.append_user(opts.payload or "")
  local reply = prompt.handle_print(opts.payload or "")
  session.append_assistant(reply, { { type = "text", text = reply } }, {})
  local saved, save_err = runtime:save()
  if not saved then
    io.stderr:write("failed to save session file: " .. tostring(save_err) .. "\n")
    runtime:shutdown()
    return false
  end
  runtime:shutdown()
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
  local runtime, loaded, load_err = bootstrap_runtime(opts)
  if not loaded then
    io.stderr:write("failed to load session file: " .. tostring(load_err) .. "\n")
    return false
  end
  local ok, reply, result = run_agent_turn(runtime, opts.payload or "")
  if not ok then
    if reply ~= nil and reply ~= "" and reply ~= "aborted" then
      io.stderr:write("agent turn failed: " .. tostring(reply) .. "\n")
    end
    runtime:shutdown()
    return false
  end
  if not result.save_ok then
    io.stderr:write("failed to save session file: " .. tostring(result.save_error) .. "\n")
    runtime:shutdown()
    return false
  end
  runtime:shutdown()
  return true
end

function M.run_compact(opts)
  if
    (not opts.session_file or opts.session_file == "")
    and not opts.resume
    and not opts.continue_recent
  then
    io.stderr:write("--compact requires --session FILE, --resume, or --continue\n")
    return false
  end
  local runtime, loaded, load_err = bootstrap_runtime(opts, {
    allow_new = false,
    on_continue_missing = function() end,
  })
  if not loaded then
    if opts.continue_recent then
      io.stderr:write("--compact --continue: " .. tostring(load_err) .. "\n")
    elseif opts.resume then
      io.stderr:write("--compact resume failed: " .. tostring(load_err) .. "\n")
    else
      io.stderr:write("--compact failed to resolve session: " .. tostring(load_err) .. "\n")
    end
    return false
  end
  local ok, summary, result = runtime:compact(opts.keep_recent)
  if not ok then
    io.stderr:write("failed to compact session\n")
    runtime:shutdown()
    return false
  end
  if not result.save_ok then
    io.stderr:write("failed to save session file: " .. tostring(result.save_error) .. "\n")
    runtime:shutdown()
    return false
  end
  runtime:shutdown()
  print(summary or "")
  return true
end

-- REPL slash-command dispatcher.
--
-- Returns (continue, quit): continue=false aborts the REPL with an
-- error, quit=true ends the loop cleanly.
local function handle_slash_command(runtime, line)
  local opts = runtime.opts
  local commands = require("psi.slash_commands")
  local action = commands.handle(line)
  if action == nil then
    io.stderr:write("unknown command\n")
    return true, false
  end
  local kind = action.kind
  if kind == "print" or kind == "ansi-print" then
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
    local ok, summary, result = runtime:compact(action.payload)
    if not ok then
      io.stderr:write("failed to compact session\n")
      return false, false
    end
    if not result.save_ok then
      io.stderr:write("failed to save session file: " .. tostring(result.save_error) .. "\n")
      return false, false
    end
    print("compaction summary:\n" .. (summary or ""))
    return true, false
  end
  if kind == "tree" then
    local payload = action.payload or {}
    local ok, result = agent.run_tree({
      target = payload.target,
      summarize = payload.summarize,
      custom_instructions = payload.custom_instructions,
      model = opts.model,
      max_tokens = opts.max_tokens,
      thinking_level = opts.thinking_level,
      reasoning_effort = opts.reasoning_effort,
    })
    if not ok then
      io.stderr:write("tree navigation failed: " .. tostring(result) .. "\n")
      return false, false
    end
    local saved, save_err = runtime:save()
    if not saved then
      io.stderr:write("failed to save session file: " .. tostring(save_err) .. "\n")
      return false, false
    end
    if result.summary and result.summary ~= "" then
      print("branch summary:\n" .. result.summary)
    end
    print("active branch leaf: " .. tostring(result.target))
    print(result.tree or session.branch_tree_text())
    return true, false
  end
  if kind == "set-model" then
    opts.model = action.payload
    print("model set to " .. tostring(opts.model))
    return true, false
  end
  if kind == "model-picker" then
    print("usage: /model <spec> (e.g. ollama/llama3.1:latest)")
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
    local ok, err = runtime:switch_session(path)
    if not ok then
      io.stderr:write("resume failed: " .. tostring(err) .. "\n")
      return true, false
    end
    print("resumed " .. path .. " (" .. tostring(psi.session_message_count()) .. " messages)")
    return true, false
  end
  if kind == "resume-picker" then
    local selected, err = session.resolve_resume_path(psi.cwd(), choose_session_cli)
    if not selected then
      io.stderr:write("resume failed: " .. tostring(err) .. "\n")
      return true, false
    end
    local ok, load_err = runtime:switch_session(selected)
    if not ok then
      io.stderr:write("resume failed: " .. tostring(load_err) .. "\n")
      return true, false
    end
    print("resumed " .. selected .. " (" .. tostring(psi.session_message_count()) .. " messages)")
    return true, false
  end
  if kind == "name" then
    session.set_display_name(action.payload)
    runtime:save()
    print("name set to '" .. tostring(action.payload) .. "'")
    return true, false
  end
  if kind == "expand" then
    -- Prompt-template expansion: treat the expanded body as a
    -- user turn. Print it so the user sees what the template
    -- actually sent (templates can be opaque for new users).
    print("> " .. (action.payload or ""))
    local ok, _, result = run_agent_turn(runtime, action.payload or "")
    if ok and not result.save_ok then
      io.stderr:write("failed to save session file: " .. tostring(result.save_error) .. "\n")
      return false, false
    end
    return true, false
  end
  io.stderr:write("unknown command\n")
  return true, false
end

function M.run_repl(opts)
  local runtime, loaded, load_err = bootstrap_runtime(opts)
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
      local ok, quit = handle_slash_command(runtime, line)
      if not ok then
        runtime:shutdown()
        return false
      end
      if quit then
        break
      end
    else
      if line ~= "" then
        psi.add_history(line)
      end
      local ok, reply, result = run_agent_turn(runtime, line)
      if ok then
        if not result.save_ok then
          io.stderr:write("failed to save session file: " .. tostring(result.save_error) .. "\n")
          runtime:shutdown()
          return false
        end
      elseif reply ~= nil and reply ~= "" and reply ~= "aborted" then
        io.stderr:write("agent turn failed: " .. tostring(reply) .. "\n")
      end
    end
  end
  runtime:shutdown()
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
  opts = opts or {}
  psi.no_context_files = not not opts.no_context_files
  if psi.prompt_templates then
    if opts.no_prompt_templates then
      psi.prompt_templates.set_enabled(false)
    end
    if opts.prompt_template_file then
      psi.prompt_templates.load_path(opts.prompt_template_file)
    end
  end
  local fn = DISPATCH[opts.mode]
  if not fn then
    io.stderr:write("psi.modes.run: unknown mode '" .. tostring(opts.mode) .. "'\n")
    return false
  end
  return not not fn(opts)
end

return M
