-- Reusable TUI chrome components.
--
-- These mirror the Component shape used by the root renderer while keeping
-- layout policy in Lua: render(width) -> lines, invalidate() marks stale.

local M = {}

local Component = {}
Component.__index = Component

local function visible_width(text)
  text = tostring(text or "")
  text = text:gsub("\27%[[%d;?]*[A-Za-z]", "")
  text = text:gsub("\27_[^\7]*\7", "")
  text = text:gsub("\27%][^\7]*\7", "")
  local width = 0
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    if byte < 0x80 or byte >= 0xC0 then
      width = width + 1
    end
    i = i + 1
  end
  return width
end

local function pad_line(text, width)
  text = tostring(text or "")
  width = math.max(1, tonumber(width) or 1)
  return text .. string.rep(" ", math.max(0, width - visible_width(text)))
end

local function new(render_fn)
  return setmetatable({
    render_fn = render_fn,
    generation = 0,
  }, Component)
end

function Component:render(width)
  if type(self.render_fn) ~= "function" then
    return {}
  end
  return self.render_fn(math.max(1, tonumber(width) or 1)) or {}
end

function Component:invalidate()
  self.generation = (self.generation or 0) + 1
end

function M.line(render_fn)
  return new(function(width)
    local text = type(render_fn) == "function" and render_fn(width) or ""
    return { pad_line(text, width) }
  end)
end

function M.block(lines_fn)
  return new(function(width)
    local source = type(lines_fn) == "function" and lines_fn(width) or lines_fn
    source = type(source) == "table" and source or {}
    local out = {}
    for i, line in ipairs(source) do
      out[i] = pad_line(line, width)
    end
    return out
  end)
end

function M.transcript(lines_fn)
  return M.block(lines_fn)
end

function M.input_box(lines_fn)
  return M.block(lines_fn)
end

return M
