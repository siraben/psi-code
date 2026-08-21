-- Large-paste compaction for the Lua-owned TUI editor.
--
-- The editor keeps a short marker in its visible input and stores the
-- normalized paste content in a private registry. Only registry-backed
-- markers are atomic; marker-like text typed by the user remains ordinary.

local tui_text = require("psi.tui_text")

local M = {}

local MAX_INLINE_LINES = 10
local MAX_INLINE_CHARS = 1000
local MARKER_PATTERN = "%[paste #(%d+) ([^%]]+)%]"

local function registry(state)
  state.editor_pastes = state.editor_pastes or {}
  return state.editor_pastes
end

local function valid_suffix(suffix)
  return suffix:match("^%+%d+ lines$") ~= nil or suffix:match("^%d+ chars$") ~= nil
end

local function character_count(text)
  local count = utf8.len(text)
  return count or #text
end

local function line_count(text)
  local count = 1
  for _ in text:gmatch("\n") do
    count = count + 1
  end
  return count
end

function M.clear(state)
  state.editor_pastes = {}
  state.editor_paste_counter = 0
  state.editor_paste_revision = (state.editor_paste_revision or 0) + 1
end

function M.clone(state)
  local out = {}
  for id, text in pairs(registry(state)) do
    out[id] = text
  end
  return {
    pastes = out,
    counter = tonumber(state.editor_paste_counter) or 0,
  }
end

function M.restore(state, snapshot)
  snapshot = type(snapshot) == "table" and snapshot or {}
  state.editor_pastes = {}
  for id, text in pairs(snapshot.pastes or {}) do
    state.editor_pastes[id] = text
  end
  state.editor_paste_counter = tonumber(snapshot.counter) or 0
  state.editor_paste_revision = (state.editor_paste_revision or 0) + 1
end

function M.compact(state, text)
  text = tostring(text or "")
  local lines = line_count(text)
  local chars = character_count(text)
  if lines <= MAX_INLINE_LINES and chars <= MAX_INLINE_CHARS then
    return text, false
  end
  local id = (tonumber(state.editor_paste_counter) or 0) + 1
  state.editor_paste_counter = id
  registry(state)[id] = text
  state.editor_paste_revision = (state.editor_paste_revision or 0) + 1
  if lines > MAX_INLINE_LINES then
    return "[paste #" .. id .. " +" .. lines .. " lines]", true
  end
  return "[paste #" .. id .. " " .. chars .. " chars]", true
end

function M.markers(state, text)
  text = tostring(text or "")
  local valid = registry(state)
  local out = {}
  local pos = 1
  while pos <= #text do
    local first, last, id_text, suffix = text:find(MARKER_PATTERN, pos)
    if first == nil then
      break
    end
    local id = tonumber(id_text)
    if id ~= nil and valid[id] ~= nil and valid_suffix(suffix) then
      out[#out + 1] = {
        start = first - 1,
        finish = last,
        id = id,
        suffix = suffix,
        text = text:sub(first, last),
      }
    end
    pos = last + 1
  end
  return out
end

function M.containing(state, text, cursor)
  cursor = math.max(0, math.min(#tostring(text or ""), tonumber(cursor) or 0))
  for _, marker in ipairs(M.markers(state, text)) do
    if cursor >= marker.start and cursor < marker.finish then
      return marker
    end
  end
  return nil
end

function M.starting_at(state, text, cursor)
  for _, marker in ipairs(M.markers(state, text)) do
    if marker.start == cursor then
      return marker
    end
  end
  return nil
end

function M.ending_at(state, text, cursor)
  for _, marker in ipairs(M.markers(state, text)) do
    if marker.finish == cursor then
      return marker
    end
  end
  return nil
end

function M.next_index(state, text, cursor)
  text = tostring(text or "")
  cursor = math.max(0, math.min(#text, tonumber(cursor) or 0))
  local marker = M.containing(state, text, cursor)
  if marker ~= nil then
    return marker.finish
  end
  return tui_text.next_grapheme_index(text, cursor)
end

function M.previous_index(state, text, cursor)
  text = tostring(text or "")
  cursor = math.max(0, math.min(#text, tonumber(cursor) or 0))
  local marker = M.ending_at(state, text, cursor)
  if marker ~= nil then
    return marker.start
  end
  if cursor > 0 then
    marker = M.containing(state, text, cursor - 1)
    if marker ~= nil then
      return marker.start
    end
  end
  return tui_text.previous_grapheme_index(text, cursor)
end

function M.index_at_or_before(state, text, cursor)
  text = tostring(text or "")
  cursor = math.max(0, math.min(#text, tonumber(cursor) or 0))
  local marker = M.containing(state, text, cursor)
  if marker ~= nil then
    return marker.start
  end
  return tui_text.grapheme_index_at_or_before(text, cursor)
end

function M.expand(state, text)
  text = tostring(text or "")
  local pastes = registry(state)
  local markers = M.markers(state, text)
  if #markers == 0 then
    return text
  end
  local out = {}
  local pos = 0
  for _, marker in ipairs(markers) do
    out[#out + 1] = text:sub(pos + 1, marker.start)
    out[#out + 1] = pastes[marker.id]
    pos = marker.finish
  end
  out[#out + 1] = text:sub(pos + 1)
  return table.concat(out)
end

-- Drop registry entries whose markers no longer exist, compact IDs in
-- ascending order, and update marker text/cursor offsets to match.
function M.reconcile(state)
  local text = tostring(state.input or "")
  local old_pastes = registry(state)
  local present = {}
  for _, marker in ipairs(M.markers(state, text)) do
    present[marker.id] = true
  end
  local ids = {}
  for id in pairs(old_pastes) do
    if present[id] then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids)
  local mapping = {}
  local new_pastes = {}
  for new_id, old_id in ipairs(ids) do
    mapping[old_id] = new_id
    new_pastes[new_id] = old_pastes[old_id]
  end

  local markers = M.markers(state, text)
  local out = {}
  local pos = 0
  local cursor = tonumber(state.cursor) or #text
  local new_cursor = cursor
  for _, marker in ipairs(markers) do
    local new_id = mapping[marker.id]
    if new_id ~= nil then
      local replacement = "[paste #" .. new_id .. " " .. marker.suffix .. "]"
      out[#out + 1] = text:sub(pos + 1, marker.start)
      out[#out + 1] = replacement
      local delta = #replacement - (marker.finish - marker.start)
      if marker.finish <= cursor then
        new_cursor = new_cursor + delta
      elseif marker.start < cursor then
        new_cursor = marker.start
      end
      pos = marker.finish
    end
  end
  out[#out + 1] = text:sub(pos + 1)
  state.input = table.concat(out)
  state.cursor = math.max(0, math.min(new_cursor, #state.input))
  state.editor_pastes = new_pastes
  state.editor_paste_counter = #ids
  state.editor_paste_revision = (state.editor_paste_revision or 0) + 1
  state.input_wrap_cache = nil
end

function M.thresholds()
  return MAX_INLINE_LINES, MAX_INLINE_CHARS
end

return M
