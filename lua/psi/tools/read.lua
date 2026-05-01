-- psi.tools.read: Read a file with offset/limit paging and head-truncation.

local records = require("psi.records")
local registry = require("psi.tool_registry")
local path_util = require("psi.path_utils")
local helpers = require("psi.tool_helpers")

local function notice(meta)
  if not meta or not meta.truncated then
    return nil
  end
  local start_line = (meta.offset or 0) + 1
  local end_line = math.min(meta.total_lines or 0, (meta.offset or 0) + (meta.limit or 0))
  local parts = {
    "[Showing lines ",
    tostring(start_line),
    "-",
    tostring(end_line),
    " of ",
    tostring(meta.total_lines or 0),
    ".",
  }
  if meta.next_offset then
    parts[#parts + 1] = " Use offset="
    parts[#parts + 1] = tostring(meta.next_offset)
    parts[#parts + 1] = " to continue."
  end
  if meta.truncated_bytes then
    parts[#parts + 1] = " Byte limit reached."
  end
  parts[#parts + 1] = "]"
  return table.concat(parts)
end

local function impl(input)
  local raw_path = registry.require_string(input, "path")
  if not raw_path then
    return records.tool_failure("read", "missing string field: path")
  end
  local resolved = path_util.resolve(raw_path) or raw_path
  local offset = registry.optional_number(input, "offset", 0)
  local limit = registry.optional_number(input, "limit", 2000)
  local source = nil
  local slice = nil

  if psi.file_exists(resolved) then
    slice = psi.read_file_slice(resolved, offset, limit)
  else
    local embedded = psi.embedded_doc and psi.embedded_doc(raw_path) or nil
    if embedded then
      local truncate = require("psi.truncate")
      local text, meta = truncate.by_lines(embedded, offset, limit)
      slice = {
        text = text,
        total_lines = meta.total_lines,
        next_offset = meta.next_offset,
        truncated = meta.truncated,
        offset = offset,
        limit = limit,
      }
      source = "embedded"
    end
  end

  if type(slice) == "table" and type(slice.text) == "string" then
    local text = slice.text
    local msg = notice(slice)
    if msg then
      text = msg .. "\n" .. text
    end
    return records.new_tool_result(true, "read", nil, {
      path = raw_path,
      resolved_path = resolved,
      text = text,
      source = source,
      offset = offset,
      limit = limit,
      total_lines = slice.total_lines,
      next_offset = slice.next_offset,
      truncated = slice.truncated,
    })
  end
  return records.tool_failure("read", "no such file: " .. tostring(raw_path))
end

return function()
  helpers.register(registry, records, {
    name = "read",
    description = "Read the contents of a file. Use this to inspect source files, configuration, and other project assets.",
    prompt_snippet = "Read file contents",
    guidelines = { "Use read to examine files instead of cat or sed." },
    input_schema = helpers.schema_object({
      path = helpers.schema_type("string"),
      offset = helpers.schema_type("number"),
      limit = helpers.schema_type("number"),
    }, { "path" }),
    impl = impl,
  })
end
