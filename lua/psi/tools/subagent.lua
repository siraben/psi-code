local records = require("psi.records")
local registry = require("psi.tool_registry")
local helpers = require("psi.tool_helpers")
local subagents = require("psi.subagents")

local MAX_TASKS = 8

local function task_schema()
  return helpers.schema_object({
    agent = helpers.schema_type("string"),
    task = helpers.schema_type("string"),
    cwd = helpers.schema_type("string"),
    model = helpers.schema_type("string"),
  }, { "task" })
end

local function summarize_results(results)
  local lines = {}
  for i, r in ipairs(results) do
    local label = string.format("[%d] %s", i, tostring(r.agent or "subagent"))
    if r.ok then
      lines[#lines + 1] = label .. " ok"
    else
      lines[#lines + 1] = label
        .. " failed: "
        .. tostring(r.error or ("exit " .. tostring(r.status)))
    end
    if r.session_path or r.log_path or r.script_path then
      lines[#lines + 1] = string.format(
        "inspect: session=%s log=%s script=%s",
        tostring(r.session_path or "-"),
        tostring(r.log_path or "-"),
        tostring(r.script_path or "-")
      )
    end
    local output = tostring(r.output or "")
    if output ~= "" then
      lines[#lines + 1] = output
    end
  end
  return table.concat(lines, "\n\n")
end

local function normalize_tasks(raw_tasks, input)
  local out = {}
  for i, task in ipairs(raw_tasks or {}) do
    local copy = {}
    if type(task) == "table" then
      for k, v in pairs(task) do
        copy[k] = v
      end
    end
    if copy.agent == nil then
      copy.agent = input.agent
    end
    if copy.cwd == nil then
      copy.cwd = input.cwd
    end
    if copy.model == nil then
      copy.model = input.model
    end
    out[i] = copy
  end
  return out
end

local function mode_and_tasks(input)
  if type(input.tasks) == "table" then
    return "parallel", normalize_tasks(input.tasks, input)
  end
  if type(input.chain) == "table" then
    return "chain", normalize_tasks(input.chain, input)
  end
  if input.mode == "parallel" and type(input.task) == "table" then
    return "parallel", normalize_tasks(input.task, input)
  end
  if input.mode == "chain" and type(input.task) == "table" then
    return "chain", normalize_tasks(input.task, input)
  end
  return "single",
    {
      {
        agent = input.agent,
        task = input.task or input.prompt,
        cwd = input.cwd,
        model = input.model,
      },
    }
end

local function validate_tasks(tasks)
  if type(tasks) ~= "table" or #tasks == 0 then
    return false, "missing task(s)"
  end
  if #tasks > MAX_TASKS then
    return false, "too many subagent tasks; max is " .. tostring(MAX_TASKS)
  end
  for i, t in ipairs(tasks) do
    if type(t) ~= "table" then
      return false, "task " .. tostring(i) .. " must be an object"
    end
    if type(t.task or t.prompt) ~= "string" or (t.task or t.prompt) == "" then
      return false, "task " .. tostring(i) .. " is missing task"
    end
  end
  return true, nil
end

local function impl(input, meta)
  input = type(input) == "table" and input or {}
  if input.list == true then
    return records.new_tool_result(true, "subagent", nil, {
      output = psi.json_encode(subagents.list()),
      agents = subagents.list(),
    })
  end

  local mode, tasks = mode_and_tasks(input)
  local ok, err = validate_tasks(tasks)
  if not ok then
    return records.tool_failure("subagent", err)
  end

  local opts = {
    cwd = input.cwd,
    model = input.model,
    tool_call_id = meta and meta.tool_call_id or nil,
  }
  local results
  if mode == "parallel" then
    results = subagents.run_parallel(tasks, opts)
  elseif mode == "chain" then
    results = subagents.run_chain(tasks, opts)
  else
    results = { subagents.run_task(tasks[1], opts) }
  end

  local all_ok = true
  for _, r in ipairs(results) do
    if not r.ok then
      all_ok = false
      break
    end
  end
  local output = summarize_results(results)
  return records.new_tool_result(all_ok, "subagent", all_ok and nil or output, {
    mode = mode,
    output = output,
    results = results,
  })
end

return function()
  helpers.register(registry, records, {
    name = "subagent",
    description = "Run one or more isolated psi child agents. Supports a single task, parallel tasks via tasks=[...], and sequential chains via chain=[...] with {previous} substitution.",
    prompt_snippet = "Delegate bounded work to isolated child agents",
    guidelines = {
      "Use subagent for independent exploration, review, planning, or bounded implementation tasks.",
      "For parallel mode, keep tasks independent and concrete.",
      "For chain mode, later tasks may reference {previous} to consume the previous output.",
    },
    input_schema = helpers.schema_object({
      agent = helpers.schema_type("string"),
      task = helpers.schema_type("string"),
      prompt = helpers.schema_type("string"),
      cwd = helpers.schema_type("string"),
      model = helpers.schema_type("string"),
      list = helpers.schema_type("boolean"),
      tasks = {
        type = "array",
        items = task_schema(),
      },
      chain = {
        type = "array",
        items = task_schema(),
      },
    }, {}),
    impl = impl,
    opts = { execution_mode = "sequential" },
  })
end
