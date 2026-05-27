-- psi.path: portable path helpers backed by C primitives.

local M = {}
local platform = require("psi.platform")

local function normalize_spaces(text)
  return (text:gsub("[\194\160]", " "))
end

function M.expand(path)
  if type(path) ~= "string" then
    return nil
  end
  return psi.path_expand(normalize_spaces(path))
end

function M.resolve(path)
  if type(path) ~= "string" then
    return nil
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

function M.to_host(path)
  return platform.to_host_path(path)
end

function M.from_host(path)
  return platform.from_host_path(path)
end

return M
