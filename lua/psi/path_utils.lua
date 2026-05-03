-- psi.path: portable path helpers backed by C primitives.

local M = {}

local function normalize_spaces(text)
  return (text:gsub("[\194\160]", " "))
end

-- Path namespaces with explicit prefixes (RAMFS, embedded resources)
-- bypass tilde expansion and cwd-relative resolution: they're already
-- absolute within their own namespace, and the C path helpers would
-- happily mangle them by stripping a leading '@'.
local function is_namespaced(path)
  return path:sub(1, 5) == "@mem/"
    or path == "@mem"
    or path:sub(1, 10) == "@embedded/"
    or path == "@embedded"
end

function M.expand(path)
  if type(path) ~= "string" then
    return nil
  end
  if is_namespaced(path) then
    return path
  end
  return psi.path_expand(normalize_spaces(path))
end

function M.resolve(path)
  if type(path) ~= "string" then
    return nil
  end
  if is_namespaced(path) then
    return path
  end
  return psi.path_resolve(normalize_spaces(path))
end

function M.join(base, name)
  if type(base) ~= "string" or type(name) ~= "string" then
    return nil
  end
  return psi.path_join(base, name)
end

function M.parent(path)
  if type(path) ~= "string" then
    return nil
  end
  return psi.parent_directory(path)
end

return M
