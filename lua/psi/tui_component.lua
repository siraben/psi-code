-- Small component primitives for the Lua-owned TUI.
--
-- Components render width-bounded logical lines. The root renderer decides
-- how those lines become terminal bytes.

local M = {}

local Component = {}
Component.__index = Component

function Component:render(width)
  if type(self.render_fn) ~= "function" then
    return {}
  end
  return self.render_fn(width) or {}
end

function Component:invalidate()
  self.generation = (self.generation or 0) + 1
  if type(self.invalidate_fn) == "function" then
    self.invalidate_fn(self)
  end
end

function M.new(render_fn, invalidate_fn)
  return setmetatable({
    render_fn = render_fn,
    invalidate_fn = invalidate_fn,
    generation = 0,
  }, Component)
end

function M.line(render_fn)
  return M.new(function(width)
    local line = type(render_fn) == "function" and render_fn(width) or ""
    return { line or "" }
  end)
end

function M.fixed(lines)
  lines = type(lines) == "table" and lines or {}
  return M.new(function()
    local out = {}
    for i, line in ipairs(lines) do
      out[i] = line or ""
    end
    return out
  end)
end

function M.stack(children)
  children = type(children) == "table" and children or {}
  return M.new(function(width)
    local out = {}
    for _, child in ipairs(children) do
      if child and type(child.render) == "function" then
        for _, line in ipairs(child:render(width)) do
          out[#out + 1] = line or ""
        end
      end
    end
    return out
  end, function()
    for _, child in ipairs(children) do
      if child and type(child.invalidate) == "function" then
        child:invalidate()
      end
    end
  end)
end

function M.cached(child)
  local cache_width
  local cache_generation
  local cache_lines
  return M.new(function(width)
    local generation = child and child.generation or 0
    if cache_lines ~= nil and cache_width == width and cache_generation == generation then
      return cache_lines
    end
    cache_width = width
    cache_generation = generation
    cache_lines = child and child:render(width) or {}
    return cache_lines
  end, function()
    cache_width = nil
    cache_generation = nil
    cache_lines = nil
    if child and type(child.invalidate) == "function" then
      child:invalidate()
    end
  end)
end

return M
