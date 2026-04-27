-- Shared TUI layout helpers.
--
-- The POSIX TUI renders through ncurses, while small ports such as
-- ReactOS may render through a native console API. Keep geometry and
-- labels here so those backends can converge on the same screen shape.

local prelude = require("psi.prelude")

local M = {}
local prompt_max_rows_override = nil

local function clamp_prompt_max_rows(rows, height)
  local max_allowed = math.max(1, height - 6)
  rows = tonumber(rows)
  if rows == nil then
    return nil
  end
  rows = math.floor(rows)
  if rows < 1 then
    rows = 1
  end
  if rows > max_allowed then
    rows = max_allowed
  end
  return rows
end

local function default_prompt_max_rows(height)
  return math.max(1, height - 6)
end

local function resolve_prompt_max_rows(configured, height)
  if prompt_max_rows_override ~= nil then
    configured = prompt_max_rows_override
  end
  return clamp_prompt_max_rows(configured, height) or default_prompt_max_rows(height)
end

function M.set_prompt_max_rows(rows)
  if rows == nil or rows == false then
    prompt_max_rows_override = nil
    return
  end
  if tonumber(rows) == nil then
    error("prompt max rows must be a number or nil", 2)
  end
  prompt_max_rows_override = rows
end

function M.geometry(width, height)
  width = math.max(40, tonumber(width) or 80)
  height = math.max(12, tonumber(height) or 24)
  local input_h = 3
  local footer_y = height - 1
  local input_y = height - input_h
  local status_y = input_y - 1
  local transcript_y = 2
  local transcript_h = math.max(1, status_y - transcript_y)
  return {
    width = width,
    height = height,
    title = "psi coding agent",
    transcript = { x = 1, y = transcript_y, w = width, h = transcript_h },
    status = { x = 1, y = status_y, w = width, h = 1 },
    input = { x = 1, y = input_y, w = width, h = input_h },
    footer = { x = 1, y = footer_y, w = width, h = 1 },
  }
end

-- Layout policy for the editable prompt area. C still owns the hard
-- terminal constraints (minimum transcript space, actual cursor
-- placement, ncurses repainting); Lua owns the presentation policy so
-- ports and user customisations can override prefixes or the nominal
-- visible-row cap without patching tui_mode.c.
function M.input_layout_table(arg)
  arg = type(arg) == "table" and arg or {}
  local height = math.max(12, tonumber(arg.height) or 24)
  return {
    max_rows = resolve_prompt_max_rows(arg.max_rows, height),
    prefix_first = " › ",
    prefix_rest = "   ",
  }
end

function M.input_layout(arg_json)
  return psi.json_encode(M.input_layout_table(prelude.safe_json_decode(arg_json, {})))
end

function M.footer_hint(arg_json)
  local tui = require("psi.tui")
  return tui.footer_hint(arg_json)
end

function M.status_line(arg_json)
  local tui = require("psi.tui")
  return tui.status_line(arg_json)
end

return M
