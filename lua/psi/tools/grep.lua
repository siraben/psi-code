-- psi.tools.grep: Search file contents for a pattern (rg backend); returns matching lines with line numbers.

local records = require("psi.records")
local registry = require("psi.tool_registry")
local path_util = require("psi.path_utils")
local helpers = require("psi.tool_helpers")
local shell = require("psi.tool_shell")
local truncate = require("psi.truncate")

local DEFAULT_LINES = truncate.DEFAULT_MAX_LINES
local DEFAULT_BYTES = truncate.DEFAULT_MAX_BYTES
local LINE_LIMIT = truncate.GREP_MAX_LINE_LENGTH

local function build_argv(pattern, path, glob, limit, context, ignore_case, literal)
  local argv = {
    "rg",
    "-n",
    "--no-heading",
    "--color",
    "never",
    "--hidden",
    "--max-count",
    tostring(limit),
  }
  if context and context > 0 then
    argv[#argv + 1] = "-C"
    argv[#argv + 1] = tostring(context)
  end
  if ignore_case then
    argv[#argv + 1] = "-i"
  end
  if literal then
    argv[#argv + 1] = "-F"
  end
  if glob then
    argv[#argv + 1] = "--glob"
    argv[#argv + 1] = glob
  end
  argv[#argv + 1] = "--"
  argv[#argv + 1] = pattern
  argv[#argv + 1] = path
  return argv
end

-- Per-line clip every match so a single huge minified-JS line doesn't
-- blow the byte budget for the whole result. Mirrors pi-mono's
-- truncateLine pass over rg output.
local function clip_lines(text)
  if not text or text == "" then
    return text, false
  end
  local out = {}
  local clipped_any = false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local clipped, was = truncate.truncate_line(line, LINE_LIMIT)
    if was then
      clipped_any = true
    end
    out[#out + 1] = clipped
  end
  -- Drop the trailing empty entry split inserted by the gmatch trick.
  if out[#out] == "" then
    out[#out] = nil
  end
  return table.concat(out, "\n"), clipped_any
end

local function impl(input, meta)
  local pattern = registry.require_string(input, "pattern")
  if not pattern then
    return records.tool_failure("grep", "missing string field: pattern")
  end
  local raw_path = registry.optional_string(input, "path", ".")
  local path = path_util.resolve(raw_path) or raw_path
  local glob = type(input.glob) == "string" and input.glob or nil
  local limit = registry.optional_number(input, "limit", 100)
  local context = registry.optional_number(input, "context", 0)
  local ignore_case = registry.optional_boolean(input, "ignoreCase", false)
  local literal = registry.optional_boolean(input, "literal", false)
  local argv = build_argv(pattern, path, glob, limit, context, ignore_case, literal)

  local tool_call_id = meta and meta.tool_call_id or nil
  local stream = shell.run_streaming_argv(argv, tool_call_id, {
    max_bytes = DEFAULT_BYTES,
    max_lines = DEFAULT_LINES,
    mode = "head",
    spill_to_disk = false, -- grep results are bounded by --max-count
  })

  local raw = stream.output or ""
  local clipped, lines_clipped = clip_lines(raw)
  local result = truncate.truncate_head(clipped, {
    max_bytes = DEFAULT_BYTES,
    max_lines = DEFAULT_LINES,
  })

  local extras = {
    path = raw_path,
    argv = argv,
    status = stream.status,
    total_bytes = stream.total_bytes,
  }

  local output_text = result.content
  if result.truncated or lines_clipped then
    extras.truncated = result.truncated
    extras.lines_clipped = lines_clipped
    local notice_parts = {}
    if result.truncated then
      local n = truncate.head_notice(result)
      if n and n ~= "" then
        notice_parts[#notice_parts + 1] = n
      end
    end
    if lines_clipped then
      notice_parts[#notice_parts + 1] = string.format(
        "[Some match lines clipped to %d chars. Use read for full lines.]",
        LINE_LIMIT
      )
    end
    if #notice_parts > 0 then
      if #output_text > 0 then
        output_text = output_text .. "\n\n" .. table.concat(notice_parts, "\n")
      else
        output_text = table.concat(notice_parts, "\n")
      end
    end
  else
    extras.truncated = false
  end

  extras.output = output_text
  local ok = (stream.status == 0)
  return records.new_tool_result(ok, "grep", nil, extras)
end

return function()
  helpers.register(registry, records, {
    name = "grep",
    description = string.format(
      "Search file contents for a pattern and return matching lines with file paths and "
        .. "line numbers. Output is truncated to %d lines or %dKB (whichever is hit first). "
        .. "Long match lines are clipped to %d chars.",
      DEFAULT_LINES,
      math.floor(DEFAULT_BYTES / 1024),
      LINE_LIMIT
    ),
    prompt_snippet = "Search file contents for patterns (prefer this over broad shell grep)",
    guidelines = { "Prefer grep over bash when searching file contents." },
    input_schema = helpers.schema_object({
      pattern = helpers.schema_type("string"),
      path = helpers.schema_type("string"),
      glob = helpers.schema_type("string"),
      ignoreCase = helpers.schema_type("boolean"),
      literal = helpers.schema_type("boolean"),
      context = helpers.schema_type("number"),
      limit = helpers.schema_type("number"),
    }, { "pattern" }),
    impl = impl,
  })
end
