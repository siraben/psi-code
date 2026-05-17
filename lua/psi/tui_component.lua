-- Small component primitives for the Lua-owned TUI.
--
-- Components render width-bounded logical lines. The root renderer decides
-- how those lines become terminal bytes.

local M = {}
local tui_text = require("psi.tui_text")

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

local function line_arrays_equal(a, b)
  a = type(a) == "table" and a or {}
  b = type(b) == "table" and b or {}
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if tostring(a[i] or "") ~= tostring(b[i] or "") then
      return false
    end
  end
  return true
end

local Block = {}
Block.__index = Block

function Block:set_lines(lines)
  lines = type(lines) == "table" and lines or {}
  if line_arrays_equal(self.lines, lines) then
    return
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = tostring(line or "")
  end
  self.lines = out
  self:invalidate()
end

function Block:set_visible(visible)
  visible = visible ~= false
  if self.visible == visible then
    return
  end
  self.visible = visible
  self:invalidate()
end

function Block:render(width)
  width = math.max(1, tonumber(width) or 1)
  if not self.visible then
    return {}
  end
  if
    self.cache_lines ~= nil
    and self.cache_width == width
    and self.cache_generation == self.generation
  then
    return self.cache_lines
  end
  local out = {}
  for i, line in ipairs(self.lines) do
    out[i] = self.pad and tui_text.pad_line(line, width) or line
  end
  self.cache_width = width
  self.cache_generation = self.generation
  self.cache_lines = out
  return out
end

function Block:invalidate()
  self.generation = (self.generation or 0) + 1
  self.cache_width = nil
  self.cache_generation = nil
  self.cache_lines = nil
end

function Block:generation_key()
  return tostring(self.generation or 0)
end

function M.block(lines, opts)
  opts = type(opts) == "table" and opts or {}
  local block = setmetatable({
    lines = {},
    pad = not not opts.pad,
    visible = opts.visible ~= false,
    generation = 0,
    cache_width = nil,
    cache_generation = nil,
    cache_lines = nil,
  }, Block)
  block:set_lines(lines or {})
  return block
end

local Spacer = {}
Spacer.__index = Spacer

function Spacer:set_rows(rows)
  rows = math.max(0, tonumber(rows) or 0)
  if self.rows == rows then
    return
  end
  self.rows = rows
  self:invalidate()
end

function Spacer:render(width)
  width = math.max(1, tonumber(width) or 1)
  if
    self.cache_lines ~= nil
    and self.cache_width == width
    and self.cache_generation == self.generation
  then
    return self.cache_lines
  end
  local out = {}
  for i = 1, self.rows do
    out[i] = string.rep(" ", width)
  end
  self.cache_width = width
  self.cache_generation = self.generation
  self.cache_lines = out
  return out
end

function Spacer:invalidate()
  self.generation = (self.generation or 0) + 1
  self.cache_width = nil
  self.cache_generation = nil
  self.cache_lines = nil
end

function Spacer:generation_key()
  return tostring(self.generation or 0)
end

function M.spacer(rows)
  return setmetatable({
    rows = math.max(0, tonumber(rows) or 0),
    generation = 0,
    cache_width = nil,
    cache_generation = nil,
    cache_lines = nil,
  }, Spacer)
end

local Container = {}
Container.__index = Container

local function component_generation_key(child)
  if child and type(child.generation_key) == "function" then
    return child:generation_key()
  end
  return tostring(child and child.generation or 0)
end

local function child_generation_key(children)
  local parts = {}
  for i, child in ipairs(children) do
    parts[i] = component_generation_key(child)
  end
  return table.concat(parts, ":")
end

function Container:add_child(child)
  self.children[#self.children + 1] = child
  self:invalidate()
end

function Container:remove_child(child)
  for i, existing in ipairs(self.children) do
    if existing == child then
      table.remove(self.children, i)
      self:invalidate()
      return true
    end
  end
  return false
end

function Container:clear()
  if #self.children == 0 then
    return
  end
  self.children = {}
  self:invalidate()
end

function Container:render(width)
  width = math.max(1, tonumber(width) or 1)
  local key = child_generation_key(self.children)
  if self.cache_lines ~= nil and self.cache_width == width and self.cache_child_key == key then
    return self.cache_lines
  end
  local out = {}
  for _, child in ipairs(self.children) do
    if child and type(child.render) == "function" then
      for _, line in ipairs(child:render(width)) do
        out[#out + 1] = line or ""
      end
    end
  end
  self.cache_width = width
  self.cache_child_key = key
  self.cache_lines = out
  return out
end

function Container:invalidate()
  self.generation = (self.generation or 0) + 1
  self.cache_width = nil
  self.cache_child_key = nil
  self.cache_lines = nil
end

function Container:generation_key()
  return tostring(self.generation or 0) .. "(" .. child_generation_key(self.children) .. ")"
end

function M.container(children)
  return setmetatable({
    children = type(children) == "table" and children or {},
    generation = 0,
    cache_width = nil,
    cache_child_key = nil,
    cache_lines = nil,
  }, Container)
end

local Text = {}
Text.__index = Text

function Text:set_text(value)
  self.text = tostring(value or "")
  self:invalidate()
end

function Text:set_bg_fn(bg_fn)
  self.bg_fn = bg_fn
  self:invalidate()
end

function Text:set_wrap_opts(opts)
  opts = type(opts) == "table" and opts or {}
  self.wrap_opts = {
    preserve_whitespace = not not opts.preserve_whitespace,
  }
  self:invalidate()
end

local function apply_bg(line, width, bg_fn)
  line = tui_text.pad_line(line or "", width)
  if type(bg_fn) == "function" then
    return bg_fn(line)
  end
  return line
end

function Text:render(width)
  width = math.max(1, tonumber(width) or 1)
  if
    self.cache_lines ~= nil
    and self.cache_width == width
    and self.cache_generation == self.generation
  then
    return self.cache_lines
  end
  local value = tostring(self.text or "")
  if value == "" or value:match("^%s*$") then
    self.cache_width = width
    self.cache_generation = self.generation
    self.cache_lines = {}
    return self.cache_lines
  end
  local content_width = math.max(1, width - (self.padding_x * 2))
  local left = string.rep(" ", self.padding_x)
  local right = string.rep(" ", self.padding_x)
  local lines = {}
  value = value:gsub("\t", "   ")
  for source in (value .. "\n"):gmatch("(.-)\n") do
    if source == "" then
      lines[#lines + 1] = apply_bg(left .. right, width, self.bg_fn)
    else
      local wrapped = tui_text.wrap_ansi(source, content_width, self.wrap_opts)
      for _, line in ipairs(wrapped) do
        lines[#lines + 1] = apply_bg(left .. line .. right, width, self.bg_fn)
      end
    end
  end
  for _ = 1, self.padding_y do
    table.insert(lines, 1, apply_bg("", width, self.bg_fn))
    lines[#lines + 1] = apply_bg("", width, self.bg_fn)
  end
  self.cache_width = width
  self.cache_generation = self.generation
  self.cache_lines = lines
  return lines
end

function Text:invalidate()
  self.generation = (self.generation or 0) + 1
  self.cache_width = nil
  self.cache_generation = nil
  self.cache_lines = nil
end

function Text:generation_key()
  return tostring(self.generation or 0)
end

function M.text(value, padding_x, padding_y, bg_fn, opts)
  opts = type(opts) == "table" and opts or {}
  return setmetatable({
    text = tostring(value or ""),
    padding_x = math.max(0, tonumber(padding_x) or 0),
    padding_y = math.max(0, tonumber(padding_y) or 0),
    bg_fn = bg_fn,
    wrap_opts = {
      preserve_whitespace = not not opts.preserve_whitespace,
    },
    generation = 0,
    cache_width = nil,
    cache_generation = nil,
    cache_lines = nil,
  }, Text)
end

local Border = {}
Border.__index = Border

function Border:set_color_fn(color_fn)
  self.color_fn = color_fn
  self:invalidate()
end

function Border:render(width)
  width = math.max(1, tonumber(width) or 1)
  if
    self.cache_lines ~= nil
    and self.cache_width == width
    and self.cache_generation == self.generation
  then
    return self.cache_lines
  end
  local line = string.rep(self.char or "─", width)
  if type(self.color_fn) == "function" then
    line = self.color_fn(line)
  end
  self.cache_width = width
  self.cache_generation = self.generation
  self.cache_lines = { line }
  return self.cache_lines
end

function Border:invalidate()
  self.generation = (self.generation or 0) + 1
  self.cache_width = nil
  self.cache_generation = nil
  self.cache_lines = nil
end

function Border:generation_key()
  return tostring(self.generation or 0)
end

function M.border(color_fn, char)
  return setmetatable({
    color_fn = color_fn,
    char = char or "─",
    generation = 0,
    cache_width = nil,
    cache_generation = nil,
    cache_lines = nil,
  }, Border)
end

local Box = {}
Box.__index = Box

function Box:add_child(child)
  self.children[#self.children + 1] = child
  self:invalidate()
end

function Box:clear()
  self.children = {}
  self:invalidate()
end

function Box:set_bg_fn(bg_fn)
  self.bg_fn = bg_fn
  self:invalidate()
end

function Box:render(width)
  width = math.max(1, tonumber(width) or 1)
  if #self.children == 0 then
    return {}
  end
  local key = child_generation_key(self.children)
  if
    self.cache_lines ~= nil
    and self.cache_width == width
    and self.cache_generation == self.generation
    and self.cache_child_key == key
  then
    return self.cache_lines
  end
  local content_width = math.max(1, width - (self.padding_x * 2))
  local left = string.rep(" ", self.padding_x)
  local child_lines = {}
  for _, child in ipairs(self.children) do
    if child and type(child.render) == "function" then
      for _, line in ipairs(child:render(content_width)) do
        child_lines[#child_lines + 1] = left .. tostring(line or "")
      end
    end
  end
  if #child_lines == 0 then
    return {}
  end
  local lines = {}
  for _ = 1, self.padding_y do
    lines[#lines + 1] = apply_bg("", width, self.bg_fn)
  end
  for _, line in ipairs(child_lines) do
    lines[#lines + 1] = apply_bg(line, width, self.bg_fn)
  end
  for _ = 1, self.padding_y do
    lines[#lines + 1] = apply_bg("", width, self.bg_fn)
  end
  self.cache_width = width
  self.cache_generation = self.generation
  self.cache_child_key = key
  self.cache_lines = lines
  return lines
end

function Box:invalidate()
  self.generation = (self.generation or 0) + 1
  self.cache_width = nil
  self.cache_generation = nil
  self.cache_child_key = nil
  self.cache_lines = nil
end

function Box:generation_key()
  return tostring(self.generation or 0) .. "(" .. child_generation_key(self.children) .. ")"
end

function M.box(padding_x, padding_y, bg_fn)
  return setmetatable({
    children = {},
    padding_x = math.max(0, tonumber(padding_x) or 0),
    padding_y = math.max(0, tonumber(padding_y) or 0),
    bg_fn = bg_fn,
    generation = 0,
    cache_width = nil,
    cache_generation = nil,
    cache_child_key = nil,
    cache_lines = nil,
  }, Box)
end

function M.stack(children)
  return M.container(children)
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
