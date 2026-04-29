-- psi.markdown: pure-Lua gsub markdown → ANSI renderer.
--
-- Two entry points:
--   M.render(text)      whole-string; returns ANSI-styled text.
--   M.new_stream()      stateful; feed(chunk) emits styled completed
--                       lines, flush() emits any trailing partial line.
--
-- Streaming design: we buffer characters until newline, then style
-- that line as a unit. Partial lines stay invisible until \n arrives.
-- This is simple and never restyles already-emitted output; the cost
-- is that single long paragraph deltas only paint on line boundaries.

local ansi = require("psi.ansi")

local M = {}

-- ---------- inline renderer ----------

local function italic(text)
  return ansi.color("3", text)
end
local function underline(text)
  return ansi.color("4", text)
end

local function sgr(code)
  if not ansi.enabled then
    return ""
  end
  return string.char(27) .. "[" .. code .. "m"
end

local function active_sgr(state)
  if not state then
    return ""
  end
  local out = {}
  if state.bold then
    out[#out + 1] = sgr("1")
  end
  if state.italic then
    out[#out + 1] = sgr("3")
  end
  return table.concat(out)
end

local function reset_then_active(state)
  if not ansi.enabled then
    return ""
  end
  return sgr("0") .. active_sgr(state)
end

local function visible_width(text)
  local width = 0
  local i = 1
  while i <= #text do
    local byte = text:byte(i)
    if byte == 27 and text:sub(i + 1, i + 1) == "[" then
      local j = i + 2
      while j <= #text and text:sub(j, j) ~= "m" do
        j = j + 1
      end
      i = j <= #text and (j + 1) or (#text + 1)
    else
      if byte < 128 or byte >= 192 then
        width = width + 1
      end
      i = i + 1
    end
  end
  return width
end

local function parse_sgr(code, tracker)
  local params = code:match("^\27%[([%d;]*)m$")
  if params == nil then
    return
  end
  if params == "" then
    params = "0"
  end
  for part in params:gmatch("[^;]+") do
    local n = tonumber(part)
    if n == 0 then
      tracker.bold = false
      tracker.dim = false
      tracker.italic = false
      tracker.underline = false
      tracker.strike = false
      tracker.fg = nil
      tracker.bg = nil
    elseif n == 1 then
      tracker.bold = true
    elseif n == 2 then
      tracker.dim = true
    elseif n == 3 then
      tracker.italic = true
    elseif n == 4 then
      tracker.underline = true
    elseif n == 9 then
      tracker.strike = true
    elseif n == 22 then
      tracker.bold = false
      tracker.dim = false
    elseif n == 23 then
      tracker.italic = false
    elseif n == 24 then
      tracker.underline = false
    elseif n == 29 then
      tracker.strike = false
    elseif n == 39 then
      tracker.fg = nil
    elseif n == 49 then
      tracker.bg = nil
    elseif (n >= 30 and n <= 37) or (n >= 90 and n <= 97) or n == 38 then
      tracker.fg = params
      break
    elseif (n >= 40 and n <= 47) or (n >= 100 and n <= 107) or n == 48 then
      tracker.bg = params
      break
    end
  end
end

local function tracker_active_sgr(tracker)
  if not ansi.enabled then
    return ""
  end
  local codes = {}
  if tracker.bold then
    codes[#codes + 1] = "1"
  end
  if tracker.dim then
    codes[#codes + 1] = "2"
  end
  if tracker.italic then
    codes[#codes + 1] = "3"
  end
  if tracker.underline then
    codes[#codes + 1] = "4"
  end
  if tracker.strike then
    codes[#codes + 1] = "9"
  end
  if tracker.fg then
    codes[#codes + 1] = tracker.fg
  end
  if tracker.bg then
    codes[#codes + 1] = tracker.bg
  end
  return #codes > 0 and sgr(table.concat(codes, ";")) or ""
end

local function ansi_tokens(text)
  local tokens = {}
  local i = 1
  while i <= #text do
    if text:byte(i) == 27 and text:sub(i + 1, i + 1) == "[" then
      local j = i + 2
      while j <= #text and text:sub(j, j) ~= "m" do
        j = j + 1
      end
      tokens[#tokens + 1] = text:sub(i, math.min(j, #text))
      i = j + 1
    else
      local start = i
      local is_space = text:byte(i) == 32
      repeat
        i = i + 1
      until i > #text
        or (text:byte(i) == 27 and text:sub(i + 1, i + 1) == "[")
        or ((text:byte(i) == 32) ~= is_space)
      tokens[#tokens + 1] = text:sub(start, i - 1)
    end
  end
  return tokens
end

local function process_sgrs(text, tracker)
  for code in text:gmatch("\27%[[%d;]*m") do
    parse_sgr(code, tracker)
  end
end

local function trim_trailing_spaces(text)
  return (text:gsub(" +$", ""))
end

local function line_end_reset(tracker)
  return tracker_active_sgr(tracker) ~= "" and sgr("0") or ""
end

local function wrap_long_token(token, width, tracker)
  local lines = {}
  local current = tracker_active_sgr(tracker)
  local current_width = 0
  local i = 1
  while i <= #token do
    if token:byte(i) == 27 and token:sub(i + 1, i + 1) == "[" then
      local j = i + 2
      while j <= #token and token:sub(j, j) ~= "m" do
        j = j + 1
      end
      local code = token:sub(i, math.min(j, #token))
      current = current .. code
      parse_sgr(code, tracker)
      i = j + 1
    else
      local char = token:sub(i, i)
      local byte = token:byte(i)
      local char_width = ((byte < 128 or byte >= 192) and 1 or 0)
      if current_width + char_width > width and current_width > 0 then
        lines[#lines + 1] = current .. line_end_reset(tracker)
        current = tracker_active_sgr(tracker)
        current_width = 0
      end
      current = current .. char
      current_width = current_width + char_width
      i = i + 1
    end
  end
  lines[#lines + 1] = current
  return lines
end

local function toggle_style(state, key)
  state[key] = not state[key]
  return state[key] and active_sgr({ [key] = true }) or reset_then_active(state)
end

local function render_emphasis(text, state)
  state = state or {}
  local out = {}
  local i = 1
  if state.bold or state.italic then
    out[#out + 1] = active_sgr(state)
  end
  while i <= #text do
    local three = text:sub(i, i + 2)
    local two = text:sub(i, i + 1)
    local one = text:sub(i, i)
    if three == "***" then
      if state.bold and state.italic then
        state.bold = false
        state.italic = false
        out[#out + 1] = reset_then_active(state)
      elseif not state.bold and not state.italic then
        state.bold = true
        state.italic = true
        out[#out + 1] = active_sgr(state)
      else
        state.bold = not state.bold
        state.italic = not state.italic
        out[#out + 1] = reset_then_active(state)
      end
      i = i + 3
    elseif two == "**" then
      out[#out + 1] = toggle_style(state, "bold")
      i = i + 2
    elseif one == "*" then
      out[#out + 1] = toggle_style(state, "italic")
      i = i + 1
    elseif two == "__" then
      out[#out + 1] = toggle_style(state, "bold")
      i = i + 2
    else
      out[#out + 1] = one
      i = i + 1
    end
  end
  if state.bold or state.italic then
    out[#out + 1] = sgr("0")
  end
  return table.concat(out)
end

-- Render inline markdown spans inside a single line.
-- Order: protect inline code and links, then render emphasis spans.
-- Placeholders use \1...\2 sentinels (never appear in normal text).
local function render_inline(text, state)
  local codes = {}
  text = text:gsub("`([^`]+)`", function(c)
    codes[#codes + 1] = c
    return "\1C" .. #codes .. "\2"
  end)

  local links = {}
  text = text:gsub("%[([^%]]+)%]%(([^%)]+)%)", function(t, u)
    links[#links + 1] = underline(t) .. ansi.dim(" (" .. u .. ")")
    return "\1L" .. #links .. "\2"
  end)

  -- Italic with underscores — only with word boundaries so snake_case
  -- variables don't get mangled. This stays line-local; the stateful
  -- emphasis scanner below handles '*' and '**' spans across newlines.
  text = text:gsub("([%s%p])_([^_\n]+)_", function(p, c)
    if p == "_" then
      return p .. "_" .. c .. "_"
    end
    return p .. italic(c)
  end)
  text = text:gsub("^_([^_\n]+)_", function(c)
    return italic(c)
  end)

  text = render_emphasis(text, state)

  -- Strikethrough ~~text~~ → dim.
  text = text:gsub("~~(.-)~~", function(c)
    return ansi.dim(c)
  end)

  -- Restore placeholders.
  text = text:gsub("\1L(%d+)\2", function(n)
    return links[tonumber(n)] or ""
  end)
  text = text:gsub("\1C(%d+)\2", function(n)
    local c = codes[tonumber(n)] or ""
    return ansi.color("33", c)
  end)

  return text
end

-- ---------- line-level renderer ----------

local function render_line(line, state)
  -- Code fence toggles: ``` or ~~~ at line start, optionally with lang.
  local fence = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
  if fence then
    state.in_code_fence = not state.in_code_fence
    return ansi.dim(line)
  end
  if state.in_code_fence then
    return ansi.dim(line)
  end

  -- Headers: # ... ######
  local hashes, rest = line:match("^(#+)%s+(.*)$")
  if hashes and #hashes <= 6 then
    local body = render_inline(rest, state)
    if #hashes == 1 then
      return ansi.bold(ansi.cyan("# " .. body))
    elseif #hashes == 2 then
      return ansi.bold("## " .. body)
    else
      return ansi.cyan(string.rep("#", #hashes) .. " " .. body)
    end
  end

  -- Horizontal rule
  if
    line:match("^%s*%-%-%-+%s*$")
    or line:match("^%s*%*%*%*+%s*$")
    or line:match("^%s*___+%s*$")
  then
    return ansi.dim(line)
  end

  -- Bullet list: -, *, + (but not horizontal-rule-like)
  local indent, body = line:match("^(%s*)[%-%*%+]%s+(.*)$")
  if indent and body then
    return indent .. ansi.cyan("•") .. " " .. render_inline(body, state)
  end

  -- Numbered list
  local num_indent, num, num_body = line:match("^(%s*)(%d+%.)%s+(.*)$")
  if num then
    return num_indent .. ansi.cyan(num) .. " " .. render_inline(num_body, state)
  end

  -- Blockquote
  local bq = line:match("^>%s?(.*)$")
  if bq then
    return ansi.dim("│ ") .. render_inline(bq, state)
  end

  -- Plain paragraph line
  return render_inline(line, state)
end

-- ---------- public API ----------

-- Render one plain (non-ANSI) wrapped display line with the given
-- fence flag. The TUI drawer calls this per wrapped line; fence
-- state is tracked across wrapped lines by the TUI's build path
-- (see psi_tui_render_wrapped) rather than here.
--
-- Memoisation: each TUI repaint runs every visible wrapped line
-- through here. Under a running stream the viewport is repainted
-- at ~20 Hz for ~40 lines — most of them unchanged between
-- frames. Caching by (fence, text) is a big win on slow hosts
-- (~50× on iSH/i686) and free on fast ones. The cache grows until
-- it hits CACHE_MAX, at which point we blow it away and start
-- over; simpler than implementing LRU, and the entry set is
-- small (one entry per distinct wrapped line currently in
-- memory).
local cache = {}
local cache_size = 0
local CACHE_MAX = 4096

-- Exposed for tests and /reload handlers that want a clean slate.
function M.clear_render_cache()
  cache = {}
  cache_size = 0
end

local function wrap_ansi_line(line, width)
  width = math.max(1, tonumber(width) or 1)
  if line == "" then
    return { "" }
  end
  if visible_width(line) <= width then
    return { line }
  end

  local wrapped = {}
  local tracker = {}
  local current = ""
  local current_width = 0

  for _, token in ipairs(ansi_tokens(line)) do
    if token:match("^\27%[") then
      current = current .. token
      parse_sgr(token, tracker)
    else
      local token_width = visible_width(token)
      local is_space = token:match("^ +$") ~= nil
      if token_width > width and not is_space then
        if current ~= "" then
          wrapped[#wrapped + 1] = trim_trailing_spaces(current) .. line_end_reset(tracker)
        end
        local broken = wrap_long_token(token, width, tracker)
        for i = 1, #broken - 1 do
          wrapped[#wrapped + 1] = broken[i]
        end
        current = broken[#broken] or tracker_active_sgr(tracker)
        current_width = visible_width(current)
      elseif current_width + token_width > width and current_width > 0 then
        wrapped[#wrapped + 1] = trim_trailing_spaces(current) .. line_end_reset(tracker)
        current = tracker_active_sgr(tracker)
        current_width = 0
        if not is_space then
          current = current .. token
          current_width = token_width
          process_sgrs(token, tracker)
        end
      else
        current = current .. token
        current_width = current_width + token_width
        process_sgrs(token, tracker)
      end
    end
  end

  if current ~= "" then
    wrapped[#wrapped + 1] = trim_trailing_spaces(current) .. line_end_reset(tracker)
  end
  return #wrapped > 0 and wrapped or { "" }
end

function M.wrap_ansi(text, width)
  text = text or ""
  local out = {}
  local start = 1
  while start <= #text do
    local nl = text:find("\n", start, true)
    local line = nl and text:sub(start, nl - 1) or text:sub(start)
    local wrapped = wrap_ansi_line(line, width)
    for _, wrapped_line in ipairs(wrapped) do
      out[#out + 1] = wrapped_line
    end
    if not nl then
      break
    end
    start = nl + 1
  end
  return #out > 0 and out or { "" }
end

function M.render_line(line, in_code_fence)
  line = line or ""
  local key = (in_code_fence and "1|" or "0|") .. line
  local hit = cache[key]
  if hit ~= nil then
    return hit
  end

  local state = { in_code_fence = in_code_fence and true or false }
  local result = render_line(line, state)

  if cache_size >= CACHE_MAX then
    cache = {}
    cache_size = 0
  end
  cache[key] = result
  cache_size = cache_size + 1
  return result
end

function M.render(text)
  if type(text) ~= "string" or text == "" then
    return text or ""
  end
  local state = { in_code_fence = false }
  local out = {}
  local start = 1
  while start <= #text do
    local nl = text:find("\n", start, true)
    if not nl then
      out[#out + 1] = render_line(text:sub(start), state)
      break
    end
    out[#out + 1] = render_line(text:sub(start, nl - 1), state) .. "\n"
    start = nl + 1
  end
  return table.concat(out)
end

-- Stream renderer. `feed(chunk)` appends to an internal buffer and
-- returns the styled text of any lines that just completed. `flush()`
-- returns the styled form of whatever is in the buffer (partial line
-- at turn end). The caller can discard the returned string if it
-- wants to rely on redraw instead.
function M.new_stream()
  local stream = {
    buffer = "",
    state = { in_code_fence = false },
  }
  function stream:feed(text)
    if type(text) ~= "string" or text == "" then
      return ""
    end
    self.buffer = self.buffer .. text
    local out = {}
    while true do
      local nl = self.buffer:find("\n", 1, true)
      if not nl then
        break
      end
      local line = self.buffer:sub(1, nl - 1)
      self.buffer = self.buffer:sub(nl + 1)
      out[#out + 1] = render_line(line, self.state) .. "\n"
    end
    return table.concat(out)
  end
  function stream:flush()
    if self.buffer == "" then
      return ""
    end
    local line = self.buffer
    self.buffer = ""
    return render_line(line, self.state)
  end
  return stream
end

return M
