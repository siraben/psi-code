local records = require("psi.records")
local registry = require("psi.tool_registry")
local path_util = require("psi.path")
local helpers = require("psi.tool_helpers")

local function impl(input)
  local raw_path = registry.optional_string(input, "path", ".")
  local path = path_util.resolve(raw_path) or raw_path
  local limit = registry.optional_number(input, "limit", 500)

  if not psi.file_exists(path) then
    return records.tool_failure("ls", "path not found: " .. tostring(raw_path))
  end
  if psi.file_type(path) ~= "directory" then
    return records.tool_failure("ls", "not a directory: " .. tostring(raw_path))
  end

  local entries = psi.list_dir(path)
  if type(entries) ~= "table" then
    return records.tool_failure("ls", "could not read directory: " .. tostring(raw_path))
  end
  table.sort(entries, function(a, b)
    return tostring(a):lower() < tostring(b):lower()
  end)

  local out = {}
  local truncated = false
  for _, name in ipairs(entries) do
    if #out >= limit then
      truncated = true
      break
    end
    local full = path_util.join(path, name) or (path .. "/" .. name)
    if psi.file_type(full) == "directory" then
      out[#out + 1] = name .. "/"
    else
      out[#out + 1] = name
    end
  end
  if #out == 0 then
    out[1] = "(empty directory)"
  end
  local text = table.concat(out, "\n")
  if truncated then
    text = text
      .. "\n\n["
      .. tostring(limit)
      .. " entries limit reached. Use a higher limit for more.]"
  end
  return records.new_tool_result(true, "ls", nil, {
    path = raw_path,
    resolved_path = path,
    output = text,
    entry_limit_reached = truncated and limit or nil,
  })
end

return function()
  helpers.register(registry, records, {
    name = "ls",
    description = "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. Includes dotfiles.",
    prompt_snippet = "List directory contents",
    guidelines = { "Prefer ls over bash for a quick directory listing." },
    input_schema = helpers.schema_object({
      path = helpers.schema_type("string"),
      limit = helpers.schema_type("number"),
    }, {}),
    impl = impl,
  })
end
