-- psi.modes: top-level runtime mode implementations.
--
-- Each mode used to live as its own C function in src/runtime/print_mode.c.
-- The C host now only inits the VM + session and delegates here; this
-- module owns the session lifecycle, REPL loop, observer wiring, and
-- command dispatch. TUI mode stays in C for now.

local agent = require("psi.agent")
local prelude = require("psi.prelude")
local prompt = require("psi.prompt")
local render = require("psi.render")
local session = require("psi.session")

local M = {}

-- ---------- rendering helpers ----------

local function fire(event, payload)
  local text = render.handle_event(event, payload or {})
  if text ~= nil and text ~= "" then psi.stdout_write(text) end
end

local json_parse_or = prelude.safe_json_decode

-- Build an observer whose callbacks stream rendered events to stdout.
local function print_observer()
  local state = {assistant_wrote_text = false}
  return state, {
    on_assistant_text_delta = function(text)
      fire("assistant-text", {text = text or ""})
      if text and text ~= "" then state.assistant_wrote_text = true end
    end,
    on_tool_call = function(id, name, input_json)
      fire("tool-call", {id = id or "", tool = name or "",
                        input = json_parse_or(input_json, {})})
    end,
    on_tool_result = function(id, name, output_json)
      local parsed = json_parse_or(output_json, nil)
      local result
      if parsed == nil then
        result = output_json and {raw = output_json} or {}
      else
        result = parsed
      end
      fire("tool-result", {id = id or "", tool = name or "", result = result})
    end,
  }
end

local function run_agent_turn(opts, user_text)
  local render_state, observer = print_observer()
  fire("before-turn", {text = user_text or ""})
  local ok, reply = agent.run_turn({
    user_text = user_text or "",
    model = opts.model,
    max_tokens = opts.max_tokens,
    observer = observer,
    abort_check = psi.is_aborted,
  })
  if not ok then return false, reply end
  fire("after-turn", {
    text = reply or "",
    ["assistant-streamed"] = render_state.assistant_wrote_text,
  })
  return true, reply
end

-- ---------- mode handlers ----------

function M.run_print(opts)
  if opts.session_file and opts.session_file ~= "" then
    session.load(opts.session_file)
  end
  session.append_user(opts.payload or "")
  local reply = prompt.handle_print(opts.payload or "")
  session.append_assistant(reply, {{type = "text", text = reply}}, {})
  if opts.session_file and opts.session_file ~= "" then
    local ok, err = session.save()
    if not ok then
      io.stderr:write("failed to save session file: " .. tostring(err) .. "\n")
      return false
    end
  end
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
  if opts.session_file and opts.session_file ~= "" then
    session.load(opts.session_file)
  end
  local ok = run_agent_turn(opts, opts.payload or "")
  if not ok then return false end
  if opts.session_file and opts.session_file ~= "" then
    local saved, err = session.save()
    if not saved then
      io.stderr:write("failed to save session file: " .. tostring(err) .. "\n")
      return false
    end
  end
  return true
end

function M.run_compact(opts)
  if not opts.session_file or opts.session_file == "" then
    io.stderr:write("--compact requires --session FILE\n")
    return false
  end
  session.load(opts.session_file)
  local ok, summary = agent.run_compact({
    keep_recent = opts.keep_recent,
    model = opts.model,
    max_tokens = opts.max_tokens,
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

local function handle_slash_command(opts, line)
  local commands = require("psi.commands")
  local action = commands.handle(line)
  if action == nil then
    io.stderr:write("unknown command\n")
    return true
  end
  if action.kind == "print" then
    print(action.payload or "")
    return true
  end
  if action.kind == "compact" then
    local ok, summary = agent.run_compact({
      keep_recent = action.payload,
      model = opts.model,
      max_tokens = opts.max_tokens,
    })
    if not ok then
      io.stderr:write("failed to compact session\n")
      return false
    end
    if opts.session_file and opts.session_file ~= "" then
      local saved, err = session.save()
      if not saved then
        io.stderr:write("failed to save session file: " .. tostring(err) .. "\n")
        return false
      end
    end
    print("compaction summary:\n" .. (summary or ""))
    return true
  end
  io.stderr:write("unknown command\n")
  return true
end

function M.run_repl(opts)
  if opts.session_file and opts.session_file ~= "" then
    session.load(opts.session_file)
  end
  print("psi coding agent")
  print("type a prompt to run the agent, /help for commands, or /quit to exit")
  while true do
    local line = psi.readline("psi> ")
    if line == nil then break end
    if line == "/quit" or line == "/q" or line == ":quit" or line == ":q" then break end
    if line:sub(1, 1) == "/" then
      if not handle_slash_command(opts, line) then return false end
    else
      if line ~= "" then psi.add_history(line) end
      local ok = run_agent_turn(opts, line)
      if ok and opts.session_file and opts.session_file ~= "" then
        local saved, err = session.save()
        if not saved then
          io.stderr:write("failed to save session file: " .. tostring(err) .. "\n")
          return false
        end
      end
    end
  end
  return true
end

-- ---------- dispatcher ----------

local DISPATCH = {
  print = M.run_print,
  eval = M.run_eval,
  ["system-prompt"] = M.run_system_prompt,
  agent = M.run_agent,
  compact = M.run_compact,
  repl = M.run_repl,
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
