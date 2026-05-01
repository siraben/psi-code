-- Shared TUI layout helpers.
--
-- The POSIX TUI renders ANSI frames from Lua. Keep geometry and labels
-- here so ports can converge on the same screen shape.

local prelude = require("psi.prelude")

local M = {}
local prompt_max_rows_override = nil

local MIN_WIDTH = 40
local DEFAULT_WIDTH = 80
local MIN_HEIGHT = 12
local DEFAULT_HEIGHT = 24
local PROMPT_RESERVED_ROWS = 6
local INPUT_BOX_ROWS = 3
local TRANSCRIPT_START_ROW = 2
local SINGLE_ROW = 1

local TITLE = "psi coding agent"
local PROMPT_PREFIX_FIRST = " › "
local PROMPT_PREFIX_REST = "   "

local function clamp_prompt_max_rows(rows, height)
  local max_allowed = math.max(SINGLE_ROW, height - PROMPT_RESERVED_ROWS)
  rows = tonumber(rows)
  if rows == nil then
    return nil
  end
  rows = math.floor(rows)
  if rows < SINGLE_ROW then
    rows = SINGLE_ROW
  end
  if rows > max_allowed then
    rows = max_allowed
  end
  return rows
end

local function default_prompt_max_rows(height)
  return math.max(SINGLE_ROW, height - PROMPT_RESERVED_ROWS)
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
  width = math.max(MIN_WIDTH, tonumber(width) or DEFAULT_WIDTH)
  height = math.max(MIN_HEIGHT, tonumber(height) or DEFAULT_HEIGHT)
  local footer_y = height - SINGLE_ROW
  local input_y = height - INPUT_BOX_ROWS
  local status_y = input_y - SINGLE_ROW
  local transcript_h = math.max(SINGLE_ROW, status_y - TRANSCRIPT_START_ROW)
  return {
    width = width,
    height = height,
    title = TITLE,
    transcript = { x = 1, y = TRANSCRIPT_START_ROW, w = width, h = transcript_h },
    status = { x = 1, y = status_y, w = width, h = SINGLE_ROW },
    input = { x = 1, y = input_y, w = width, h = INPUT_BOX_ROWS },
    footer = { x = 1, y = footer_y, w = width, h = SINGLE_ROW },
  }
end

-- Layout policy for the editable prompt area. Lua owns the presentation
-- policy so ports and user customisations can override prefixes or the
-- nominal visible-row cap without patching tui_mode.c.
function M.input_layout_table(arg)
  arg = type(arg) == "table" and arg or {}
  local height = math.max(MIN_HEIGHT, tonumber(arg.height) or DEFAULT_HEIGHT)
  return {
    max_rows = resolve_prompt_max_rows(arg.max_rows, height),
    prefix_first = PROMPT_PREFIX_FIRST,
    prefix_rest = PROMPT_PREFIX_REST,
  }
end

function M.input_layout(arg_json)
  return psi.json_encode(M.input_layout_table(prelude.safe_json_decode(arg_json, {})))
end

function M.footer_hint(arg_json)
  local tui = require("psi.tui_status")
  return tui.footer_hint(arg_json)
end

function M.status_line(arg_json)
  local tui = require("psi.tui_status")
  return tui.status_line(arg_json)
end

return M
