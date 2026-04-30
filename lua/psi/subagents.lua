-- psi.subagents: lightweight child-agent launcher for the subagent tool.

local prelude = require("psi.prelude")
local shell = require("psi.tool_shell")
local sched = require("psi.sched")
local settings = require("psi.settings")

local M = {}

local BUILTINS = {
  scout = {
    name = "scout",
    description = "Explore code and report concise findings without editing files.",
    tools = { "read", "grep", "find", "ls" },
    prompt = "You are a read-only exploration subagent. Inspect the codebase, answer the assigned question with file paths and concrete evidence, and do not edit files.",
  },
  planner = {
    name = "planner",
    description = "Break a task into an implementation plan without editing files.",
    tools = { "read", "grep", "find", "ls", "update_plan" },
    prompt = "You are a planning subagent. Produce a practical implementation plan grounded in the repository. Do not edit files.",
  },
  reviewer = {
    name = "reviewer",
    description = "Review changes for bugs, regressions, and missing tests.",
    tools = { "read", "grep", "find", "ls", "bash" },
    prompt = "You are a code review subagent. Lead with concrete findings ordered by severity, include file references, and keep summaries brief.",
  },
  worker = {
    name = "worker",
    description = "Implement a bounded code change in the current workspace.",
    tools = {
      "read",
      "grep",
      "find",
      "ls",
      "bash",
      "edit",
      "write",
      "apply_patch",
      "update_plan",
    },
    prompt = "You are an implementation subagent. Make only the assigned changes, respect existing user edits, run focused verification when practical, and report changed files.",
  },
}

local function split_csv(text)
  local out = {}
  if type(text) ~= "string" then
    return out
  end
  for part in (text .. ","):gmatch("([^,]*),") do
    part = prelude.trim(part)
    if part ~= "" then
      out[#out + 1] = part
    end
  end
  return out
end

local function parse_frontmatter(raw)
  local fm, body = {}, raw
  if type(raw) ~= "string" or raw:sub(1, 3) ~= "---" then
    return fm, raw or ""
  end
  local rest = raw:sub(4)
  if rest:sub(1, 1) == "\n" then
    rest = rest:sub(2)
  elseif rest:sub(1, 2) == "\r\n" then
    rest = rest:sub(3)
  end
  local close_idx = rest:find("\n%-%-%-\r?\n") or rest:find("\n%-%-%-$")
  if close_idx == nil then
    return fm, raw
  end
  local header = rest:sub(1, close_idx - 1)
  local after = rest:sub(close_idx):gsub("^\n%-%-%-\r?\n?", "")
  for line in (header .. "\n"):gmatch("([^\n]*)\n") do
    local k, v = line:match("^%s*([%w%-_]+)%s*:%s*(.-)%s*$")
    if k then
      v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
      fm[k] = v
    end
  end
  return fm, after
end

local function list_markdown(dir)
  if not dir or dir == "" or not psi.file_exists(dir) then
    return {}
  end
  local entries = psi.list_dir(dir)
  if type(entries) ~= "table" then
    return {}
  end
  local out = {}
  for _, name in ipairs(entries) do
    if type(name) == "string" and name:match("%.md$") then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local function load_dir(agents, dir)
  for _, name in ipairs(list_markdown(dir)) do
    local path = prelude.path_join(dir, name)
    local raw = psi.read_file(path)
    if raw then
      local fm, body = parse_frontmatter(raw)
      local stem = name:gsub("%.md$", "")
      local agent_name = fm.name and fm.name ~= "" and fm.name or stem
      agents[agent_name] = {
        name = agent_name,
        description = fm.description or "",
        model = fm.model,
        tools = split_csv(fm.tools or fm.tool),
        prompt = body,
        path = path,
      }
    end
  end
end

local function load_project_agents(agents)
  local dirs = {}
  local dir = psi.cwd()
  while type(dir) == "string" and dir ~= "" do
    dirs[#dirs + 1] = prelude.path_join(dir, ".psi/agents")
    local parent = psi.parent_directory(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  for i = #dirs, 1, -1 do
    load_dir(agents, dirs[i])
  end
end

function M.list()
  local agents = {}
  for name, agent in pairs(BUILTINS) do
    local copy = {}
    for k, v in pairs(agent) do
      if type(v) == "table" then
        local xs = {}
        for i, item in ipairs(v) do
          xs[i] = item
        end
        copy[k] = xs
      else
        copy[k] = v
      end
    end
    agents[name] = copy
  end

  local env_dirs = os.getenv("PSI_AGENTS_DIR") or ""
  for dir in (env_dirs .. ":"):gmatch("([^:]*):") do
    if dir ~= "" then
      load_dir(agents, dir)
    end
  end
  local home = os.getenv("HOME")
  if home and home ~= "" then
    load_dir(agents, prelude.path_join(home, ".config/psi/agents"))
  end
  load_project_agents(agents)
  return agents
end

function M.resolve(name)
  if type(name) ~= "string" or name == "" then
    return M.list().worker or BUILTINS.worker
  end
  local agent = M.list()[name] or BUILTINS[name]
  if agent then
    return agent
  end
  return nil, "unknown subagent: " .. name
end

local function psi_command()
  local command = os.getenv("PSI_SUBAGENT_COMMAND")
  if command and command ~= "" then
    return command
  end
  local bin = os.getenv("PSI_BIN")
  if bin and bin ~= "" then
    return shell.quote(psi.path_resolve(bin) or bin)
  end
  if psi.file_exists("./build/psi") then
    return shell.quote(psi.path_resolve("./build/psi") or "./build/psi")
  end
  return shell.quote("psi")
end

local function safe_name(text)
  text = tostring(text or "subagent"):gsub("[^%w_.-]+", "-")
  text = text:gsub("^-+", ""):gsub("-+$", "")
  if text == "" then
    return "subagent"
  end
  return text:sub(1, 48)
end

local artifact_seq = 0
local artifact_token = safe_name(tostring({}):gsub("[^%w]+", "")):sub(-12)

local function artifact_exists(base)
  return psi.file_exists(base .. ".log")
    or psi.file_exists(base .. ".jsonl")
    or psi.file_exists(base .. ".sh")
    or psi.file_exists(base .. ".lock")
end

local function artifact_paths(agent_name)
  local configured_root = settings.get("subagent.dir", ".psi/subagents")
  local root = psi.path_resolve(configured_root) or configured_root
  local name = safe_name(agent_name)
  local base
  psi.mkdir_parent(prelude.path_join(root, ".keep"))
  for _ = 1, 1024 do
    artifact_seq = artifact_seq + 1
    local stamp = table.concat({
      tostring(os.time()),
      artifact_token,
      tostring(artifact_seq),
      name,
    }, "-")
    base = prelude.path_join(root, stamp)
    if not artifact_exists(base) then
      local lock_path = base .. ".lock"
      local ok = os.execute("mkdir " .. shell.quote(lock_path) .. " >/dev/null 2>&1")
      if ok == true or ok == 0 then
        local artifacts = {
          root = root,
          log_path = base .. ".log",
          session_path = base .. ".jsonl",
          script_path = base .. ".sh",
          lock_path = lock_path,
        }
        if not psi.file_write(artifacts.script_path, "# reserved psi subagent artifact\n") then
          return nil, "failed to reserve subagent artifact path"
        end
        return artifacts, nil
      end
    end
  end
  return nil, "failed to reserve a unique subagent artifact path"
end

local function task_prompt(agent, task)
  local parts = {
    "You are running as a psi subagent named ",
    agent.name or "worker",
    ".\n\n",
  }
  if agent.prompt and agent.prompt ~= "" then
    parts[#parts + 1] = agent.prompt
    parts[#parts + 1] = "\n\n"
  end
  parts[#parts + 1] = "Assigned task:\n"
  parts[#parts + 1] = task or ""
  return table.concat(parts)
end

local function model_for(agent, fallback)
  if type(fallback) == "string" and fallback ~= "" then
    return fallback
  end
  if type(agent.model) == "string" and agent.model ~= "" then
    return agent.model
  end
  local configured = settings.get("subagent.model", nil)
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  return fallback
end

local function build_command(agent, task, opts)
  opts = opts or {}
  local cwd = opts.cwd or psi.cwd()
  local model = model_for(agent, opts.model)
  local artifacts, artifact_err = artifact_paths(agent.name)
  if not artifacts then
    return nil, artifact_err
  end
  psi.mkdir_parent(artifacts.log_path)
  psi.mkdir_parent(artifacts.session_path)
  local command = {
    "set -eu\n",
    "cd ",
    shell.quote(cwd),
    "\n",
    "echo ",
    shell.quote("subagent: " .. tostring(agent.name or "worker")),
    "\n",
    "echo ",
    shell.quote("cwd: " .. tostring(cwd)),
    "\n",
    "echo ",
    shell.quote("session: " .. artifacts.session_path),
    "\n",
    "echo ",
    shell.quote("log: " .. artifacts.log_path),
    "\n",
    "echo ",
    shell.quote("task: " .. tostring(task or "")),
    "\n",
  }
  if agent.tools and #agent.tools > 0 then
    command[#command + 1] = "export PSI_ACTIVE_TOOLS="
    command[#command + 1] = shell.quote(table.concat(agent.tools, ","))
    command[#command + 1] = "\n"
  end
  command[#command + 1] = psi_command()
  command[#command + 1] = " --session "
  command[#command + 1] = shell.quote(artifacts.session_path)
  if model and model ~= "" then
    command[#command + 1] = " --model "
    command[#command + 1] = shell.quote(model)
  end
  command[#command + 1] = " --agent "
  command[#command + 1] = shell.quote(task_prompt(agent, task))
  command[#command + 1] = "\n"
  local script = table.concat(command)
  if not psi.file_write(artifacts.script_path, script) then
    return nil, "failed to write subagent script"
  end
  local wrapped = table.concat({
    "sh ",
    shell.quote(artifacts.script_path),
    " > ",
    shell.quote(artifacts.log_path),
    " 2>&1; status=$?; cat ",
    shell.quote(artifacts.log_path),
    "; exit $status",
  })
  artifacts.command = wrapped
  artifacts.cwd = cwd
  artifacts.model = model
  artifacts.tools = agent.tools
  return artifacts
end

function M.run_task(spec, opts)
  opts = opts or {}
  spec = type(spec) == "table" and spec or {}
  local task = spec.task or spec.prompt
  if type(task) ~= "string" or task == "" then
    return {
      ok = false,
      agent = spec.agent or "worker",
      task = "",
      error = "missing task",
      output = "",
    }
  end
  local agent, agent_err = M.resolve(spec.agent)
  if not agent then
    return {
      ok = false,
      agent = spec.agent or "subagent",
      task = task,
      error = agent_err or "unknown subagent",
      output = "",
    }
  end
  local artifacts, artifact_err = build_command(agent, task, {
    cwd = spec.cwd or opts.cwd,
    model = spec.model or opts.model,
  })
  if not artifacts then
    return {
      ok = false,
      agent = agent.name,
      task = task,
      error = artifact_err or "failed to build subagent command",
      output = "",
    }
  end
  local stream = shell.run_streaming(artifacts.command, opts.tool_call_id, {
    max_bytes = opts.max_bytes or 65536,
    max_lines = opts.max_lines or 2000,
    mode = "tail",
    progress = "truncated",
    truncate_final = true,
    notice = "tail",
  })
  return {
    ok = stream.status == 0,
    agent = agent.name,
    task = task,
    command = artifacts.command,
    cwd = artifacts.cwd,
    model = artifacts.model,
    tools = artifacts.tools,
    log_path = artifacts.log_path,
    script_path = artifacts.script_path,
    session_path = artifacts.session_path,
    status = stream.status,
    output = stream.output or "",
    truncated = stream.truncated,
    temp_file_path = stream.temp_file_path,
  }
end

function M.run_parallel(tasks, opts)
  local fns = {}
  for i, spec in ipairs(tasks) do
    fns[i] = function()
      return M.run_task(spec, opts)
    end
  end
  local raw = sched.run_all(fns)
  local out = {}
  for i, entry in ipairs(raw) do
    if entry.ok and entry.values then
      out[i] = entry.values[1]
    else
      out[i] = {
        ok = false,
        agent = tasks[i] and tasks[i].agent or "worker",
        error = entry.error or "subagent failed",
        output = "",
      }
    end
  end
  return out
end

function M.run_chain(chain, opts)
  local results = {}
  local previous = ""
  for i, spec in ipairs(chain) do
    local copy = {}
    for k, v in pairs(spec) do
      copy[k] = v
    end
    if type(copy.task) == "string" then
      copy.task = copy.task:gsub("{previous}", function()
        return previous
      end)
    end
    local result = M.run_task(copy, opts)
    results[i] = result
    previous = result.output or ""
    if not result.ok then
      break
    end
  end
  return results
end

return M
