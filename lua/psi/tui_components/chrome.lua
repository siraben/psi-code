-- Reusable TUI chrome components.
--
-- These mirror the Component shape used by the root renderer while keeping
-- layout policy in Lua: render(width) -> lines, invalidate() marks stale.

local tui_component = require("psi.tui_component")
local tui_text = require("psi.tui_text")

local M = {}

function M.line(render_fn)
  return tui_component.new(function(width)
    local text = type(render_fn) == "function" and render_fn(width) or ""
    return { tui_text.pad_line(text, width) }
  end)
end

function M.block(lines_fn)
  return tui_component.new(function(width)
    local source = type(lines_fn) == "function" and lines_fn(width) or lines_fn
    source = type(source) == "table" and source or {}
    local out = {}
    for i, line in ipairs(source) do
      out[i] = tui_text.pad_line(line, width)
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
