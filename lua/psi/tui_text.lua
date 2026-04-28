-- Shared terminal text helpers for Lua-owned TUI rendering.

local M = {}

local EMPTY = ""
local ANSI_PATTERN_CSI = "\27%[[%d;?]*[A-Za-z]"
local ANSI_PATTERN_KEYPAD = "\27[=>]"
local ANSI_PATTERN_APC = "\27_[^\7]*\7"
local ANSI_PATTERN_OSC = "\27%][^\7]*\7"

function M.strip_ansi(text)
  text = tostring(text or EMPTY)
  text = text:gsub(ANSI_PATTERN_CSI, EMPTY)
  text = text:gsub(ANSI_PATTERN_KEYPAD, EMPTY)
  text = text:gsub(ANSI_PATTERN_APC, EMPTY)
  text = text:gsub(ANSI_PATTERN_OSC, EMPTY)
  return text
end

function M.visible_width(text)
  text = M.strip_ansi(text)
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

function M.pad_line(text, width)
  text = tostring(text or EMPTY)
  width = math.max(1, tonumber(width) or 1)
  return text .. string.rep(" ", math.max(0, width - M.visible_width(text)))
end

function M.byte_index_for_width(text, width)
  text = M.strip_ansi(text)
  width = math.max(0, tonumber(width) or 0)
  if width <= 0 then
    return 0
  end
  local seen = 0
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    if byte < 0x80 or byte >= 0xC0 then
      seen = seen + 1
      if seen > width then
        return i - 1
      end
    end
    i = i + 1
  end
  return #text
end

return M
