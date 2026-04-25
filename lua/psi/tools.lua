-- psi.tools: built-in tool implementations.
--
-- Each tool is a records.Tool registered into the registry. Implementations
-- receive a plain table input (parsed from JSON by the C FFI glue) and
-- return a records.ToolResult.

local records = require("psi.records")
local registry = require("psi.tool_registry")
local shell = require("psi.tool_shell")
local prelude = require("psi.prelude")
local platform = require("psi.platform")

local M = {}

-- ---------- schema helpers ----------

local function schema_type(t)
  return { type = t }
end

local function schema_object(properties, required)
  return {
    type = "object",
    properties = properties,
    required = prelude.as_array(required),
  }
end

-- ---------- read ----------

local function impl_read(input)
  local path = registry.require_string(input, "path")
  if not path then
    return records.tool_failure("read", "missing string field: path")
  end
  -- Disk first; if the file isn't there and the path matches an
  -- embedded psi doc (README.md, docs/*.md), serve the bundled copy
  -- so the agent can self-describe regardless of cwd.
  if psi.file_exists(path) then
    return records.new_tool_result(true, "read", nil,
      { path = path, text = psi.read_file(path) })
  end
  local embedded = psi.embedded_doc and psi.embedded_doc(path) or nil
  if embedded then
    return records.new_tool_result(true, "read", nil,
      { path = path, text = embedded, source = "embedded" })
  end
  return records.tool_failure("read",
    "no such file: " .. tostring(path))
end

-- ---------- write ----------

local function impl_write(input)
  local path = registry.require_string(input, "path")
  local content = input.content or input.text
  if not path then
    return records.tool_failure("write", "missing string field: path")
  end
  if type(content) ~= "string" then
    return records.tool_failure("write", "missing string field: content")
  end
  if not psi.file_write(path, content) then
    return records.tool_failure("write", "could not write full file")
  end
  return records.new_tool_result(true, "write", nil, {
    path = path,
    bytes_written = #content,
  })
end

-- ---------- edit ----------

local function apply_edits(text, edits)
  local current, count = text, 0
  for _, entry in ipairs(edits) do
    if type(entry) ~= "table" then
      return nil, nil
    end
    local old_text, new_text = entry.oldText, entry.newText
    if type(old_text) ~= "string" or type(new_text) ~= "string" then
      return nil, nil
    end
    local next_text = prelude.replace_first(current, old_text, new_text)
    if not next_text then
      return nil, nil
    end
    current = next_text
    count = count + 1
  end
  return current, count
end

local function impl_edit(input)
  local path = registry.require_string(input, "path")
  if not path then
    return records.tool_failure("edit", "missing string field: path")
  end
  local edits = input.edits
  local old_text, new_text = input.oldText, input.newText
  local original = prelude.safe_read(path)
  if not original then
    return records.tool_failure("edit", "could not read file")
  end

  local edited, replacements
  if type(edits) == "table" and #edits > 0 then
    edited, replacements = apply_edits(original, edits)
  elseif type(old_text) == "string" and type(new_text) == "string" then
    edited = prelude.replace_first(original, old_text, new_text)
    replacements = edited and 1 or nil
  elseif type(old_text) ~= "string" then
    return records.tool_failure("edit", "missing string field: oldText")
  elseif type(new_text) ~= "string" then
    return records.tool_failure("edit", "missing string field: newText")
  end

  if not edited then
    return records.tool_failure("edit", "target text not found")
  end
  if not psi.file_write(path, edited) then
    return records.tool_failure("edit", "could not write full file")
  end
  return records.new_tool_result(true, "edit", nil, {
    path = path,
    replacements = replacements,
  })
end

-- ---------- bash ----------

local function impl_bash(input, meta)
  local command = registry.require_string(input, "command")
  if not command then
    return records.tool_failure("bash", "missing string field: command")
  end
  return shell.run_tool("bash", command, nil, true, meta)
end

-- ---------- grep ----------

local function build_grep_command(pattern, path, glob, limit, context, ignore_case, literal)
  if platform.is_plan9() then
    -- Plan 9 grep has no -r; enumerate files first with walk(1).
    local flags = "-n"
    if ignore_case then flags = flags .. " -i" end
    if literal     then flags = flags .. " -F" end
    return "g " .. flags .. " " .. shell.quote(pattern)
           .. " `{walk -f " .. shell.quote(path) .. "}"
           .. " | sed " .. tostring(limit) .. "q"
  end
  local rg_flags = "-n --no-heading --color never --hidden --max-count "
                   .. tostring(limit)
  if context and context > 0 then rg_flags = rg_flags .. " -C " .. tostring(context) end
  if ignore_case then rg_flags = rg_flags .. " -i" end
  if literal     then rg_flags = rg_flags .. " -F" end
  if glob        then rg_flags = rg_flags .. " --glob " .. shell.quote(glob) end
  local rg_cmd = "rg " .. rg_flags .. " " .. shell.quote(pattern) .. " " .. shell.quote(path)

  local posix_flags = "-rn --color=never"
  if ignore_case then posix_flags = posix_flags .. " -i" end
  if literal     then posix_flags = posix_flags .. " -F" end
  local posix_cmd = "grep " .. posix_flags .. " "
                    .. shell.quote(pattern) .. " " .. shell.quote(path)
                    .. " | sed " .. tostring(limit) .. "q"

  return "if command -v rg >/dev/null 2>&1; then " .. rg_cmd
         .. "; else " .. posix_cmd .. "; fi"
end

local function impl_grep(input, meta)
  local pattern = registry.require_string(input, "pattern")
  if not pattern then
    return records.tool_failure("grep", "missing string field: pattern")
  end
  local path = registry.optional_string(input, "path", ".")
  local glob = type(input.glob) == "string" and input.glob or nil
  local limit = registry.optional_number(input, "limit", 100)
  local context = registry.optional_number(input, "context", 0)
  local ignore_case = registry.optional_boolean(input, "ignoreCase", false)
  local literal = registry.optional_boolean(input, "literal", false)
  local command = build_grep_command(pattern, path, glob, limit, context, ignore_case, literal)
  return shell.run_tool("grep", command, path, true, meta)
end

-- ---------- find ----------

local function impl_find(input, meta)
  local pattern = registry.require_string(input, "pattern")
  if not pattern then
    return records.tool_failure("find", "missing string field: pattern")
  end
  local path = registry.optional_string(input, "path", ".")
  local limit = registry.optional_number(input, "limit", 1000)
  local command
  if platform.is_plan9() then
    -- Plan 9 has no fd; walk(1) emits names without stat'ing.
    command = "walk -f " .. shell.quote(path)
              .. " | grep " .. shell.quote(pattern)
              .. " | sed " .. tostring(limit) .. "q"
  else
    command = "if command -v fd >/dev/null 2>&1; then "
      .. "fd --hidden --max-results " .. tostring(limit)
      .. " --glob " .. shell.quote(pattern) .. " " .. shell.quote(path)
      .. "; else find " .. shell.quote(path)
      .. " -type f -name " .. shell.quote(pattern)
      .. " 2>/dev/null | head -n " .. tostring(limit) .. "; fi"
  end
  return shell.run_tool("find", command, path, true, meta)
end

-- ---------- ls ----------

local function impl_ls(input, meta)
  local path = registry.optional_string(input, "path", ".")
  local limit = registry.optional_number(input, "limit", 500)
  -- Plain `ls PATH | sed`: portable. Linux/BSD ls go one-entry-per-line
  -- when stdout isn't a tty (which it isn't here, piped to sed); Plan 9
  -- ls always does, and rejects `-1A`.
  local command = "ls " .. shell.quote(path) .. " | sed -n '1," .. tostring(limit) .. "p'"
  return shell.run_tool("ls", command, path, true, meta)
end

-- ---------- lua (runtime inspect / eval) ----------

local function eval_to_string(expression)
  local ok, value = prelude.eval_expression(expression)
  if not ok then
    return "error: " .. tostring(value)
  end
  if type(value) == "string" then
    return value
  end
  return tostring(value)
end

local function impl_lua(input)
  local mode = registry.optional_string(input, "mode", "summary")
  local expression = input.expression or input.code
  if mode == "summary" or mode == "inspect" then
    return records.new_tool_result(true, "lua", nil, {
      mode = mode,
      result = require("psi.prompt").runtime_summary(),
    })
  elseif mode == "eval" then
    if type(expression) ~= "string" then
      return records.tool_failure("lua", "missing string field: expression")
    end
    return records.new_tool_result(true, "lua", nil, {
      mode = mode,
      expression = expression,
      result = eval_to_string(expression),
    })
  end
  return records.tool_failure("lua", "unsupported mode")
end

-- ---------- registrations ----------

local edit_item_schema = schema_object({
  oldText = schema_type("string"),
  newText = schema_type("string"),
}, { "oldText", "newText" })

registry.register(
  records.new_tool(
    "read",
    "Read the contents of a file. Use this to inspect source files, configuration, and other project assets.",
    "Read file contents",
    { "Use read to examine files instead of cat or sed." },
    schema_object({ path = schema_type("string") }, { "path" }),
    impl_read
  )
)

-- Tool name is `bash` for Anthropic-tool-set compatibility, but the
-- underlying shell is /bin/sh on Linux/macOS and /bin/rc on Plan 9.
-- Tell the agent so it issues correct syntax on the first try
-- instead of watching its bash-isms fail.
local function bash_description()
  if platform.is_plan9() then
    return "Execute a shell command via /bin/rc (Plan 9). "
        .. "Note: this is rc, not bash — use `>[2]/dev/null`, "
        .. "`var=value cmd`, `for(x in list) cmd`, etc."
  end
  return "Execute a shell command in the current working directory and return its output."
end

registry.register(
  records.new_tool(
    "bash",
    bash_description(),
    "Execute shell commands (ls, rg, find, tests, git, build commands). On Plan 9 this is rc, not bash — adjust syntax accordingly.",
    { "Use the shell tool for commands such as ls, rg, find, git, and tests." },
    schema_object({
      command = schema_type("string"),
      timeout = schema_type("number"),
    }, { "command" }),
    impl_bash
  )
)

registry.register(
  records.new_tool(
    "edit",
    "Edit a single file using exact text replacement. Prefer small, precise edits over broad rewrites.",
    "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
    {
      "Use edit for precise changes where old text can be matched exactly.",
      "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[].",
      "Keep edits[].oldText as small as possible while still being unique in the file.",
    },
    schema_object({
      path = schema_type("string"),
      edits = { type = "array", items = edit_item_schema },
    }, { "path", "edits" }),
    impl_edit
  )
)

registry.register(
  records.new_tool(
    "write",
    "Write content to a file. Creates the file if it does not exist and overwrites it if it does.",
    "Create or overwrite files",
    { "Use write for new files or full rewrites." },
    schema_object({
      path = schema_type("string"),
      content = schema_type("string"),
    }, { "path", "content" }),
    impl_write
  )
)

registry.register(
  records.new_tool(
    "grep",
    "Search file contents for a pattern and return matching lines with file paths and line numbers.",
    "Search file contents for patterns (prefer this over broad shell grep)",
    { "Prefer grep over bash when searching file contents." },
    schema_object({
      pattern = schema_type("string"),
      path = schema_type("string"),
      glob = schema_type("string"),
      ignoreCase = schema_type("boolean"),
      literal = schema_type("boolean"),
      context = schema_type("number"),
      limit = schema_type("number"),
    }, { "pattern" }),
    impl_grep
  )
)

registry.register(
  records.new_tool(
    "find",
    "Find files by glob pattern relative to a directory.",
    "Find files by glob pattern",
    { "Prefer find over bash when locating files." },
    schema_object({
      pattern = schema_type("string"),
      path = schema_type("string"),
      limit = schema_type("number"),
    }, { "pattern" }),
    impl_find
  )
)

registry.register(
  records.new_tool(
    "ls",
    "List directory contents.",
    "List directory contents",
    { "Prefer ls over bash for a quick directory listing." },
    schema_object({
      path = schema_type("string"),
      limit = schema_type("number"),
    }, {}),
    impl_ls
  )
)

registry.register(
  records.new_tool(
    "lua",
    "Inspect or evaluate expressions in psi's embedded Lua runtime. Use this to inspect loaded helpers, prompt state, tool specs, or runtime environment.",
    "Inspect or evaluate the embedded Lua runtime and helper environment",
    {
      "Use lua with mode summary to inspect the current runtime and helper environment.",
      "Use lua with mode eval and an expression string to inspect or interact with psi's Lua state.",
    },
    schema_object({
      mode = schema_type("string"),
      expression = schema_type("string"),
      code = schema_type("string"),
    }, {}),
    impl_lua
  )
)

-- Expose the registry surface on this module so boot.lua can publish it
-- as psi.tools.* (C glue calls psi.tools.dispatch_alist etc.)
M.dispatch = registry.dispatch
M.dispatch_alist = registry.dispatch_alist
M.select_specs = registry.select_specs
M.all = registry.all
M.find = registry.find
M.register = registry.register
M.add_before_hook = registry.add_before_hook
M.add_after_hook = registry.add_after_hook
M.clear_hooks = registry.clear_hooks
M.set_active = registry.set_active
M.get_active = registry.get_active
M.active = registry.active

-- Helper for before-hooks to cleanly cancel a tool call. Returning
-- the result from a before-hook short-circuits dispatch — the tool's
-- real impl is never invoked, and the returned ToolResult becomes
-- what the LLM sees. Use this when denying permission, blocking a
-- dangerous command, or substituting a stubbed reply in tests:
--
--   psi.tools.add_before_hook(function(name, input)
--     if name == "bash" and input.command:find("rm %-rf") then
--       return psi.tools.cancel("refused: destructive rm -rf")
--     end
--   end)
--
-- `reason` is surfaced to the model in the error field so it can
-- explain the failure. If `tool_name` is supplied it's recorded on
-- the result; otherwise the tool name is filled in by the dispatcher.
function M.cancel(reason, tool_name)
  return records.tool_failure(tool_name or "tool",
                              reason or "cancelled by before-hook")
end

return M
