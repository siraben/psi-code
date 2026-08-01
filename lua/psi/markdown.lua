-- psi.markdown: pure-Lua markdown token renderer.
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

local PI_ACCENT = "36" -- mdCode / list bullets, theme accent
local PI_HEADING = "33" -- mdHeading, theme warning/gold slot
local PI_LINK = "34" -- mdLink, theme header/link slot
local PI_GRAY = "38;5;242" -- mdQuote/mdHr/toolOutput, theme chrome slot

local RESET = string.char(27) .. "[0m"
local RESET_PATTERN = string.char(27) .. "%[0m"

local function is_inline_syntax_byte(byte)
  return byte == 42 -- *
    or byte == 91 -- [
    or byte == 92 -- \
    or byte == 95 -- _
    or byte == 96 -- `
    or byte == 126 -- ~
end

-- ---------- inline renderer ----------

local function italic(text)
  return ansi.color("3", text)
end
local function underline(text)
  return ansi.color("4", text)
end

local function is_alnum_byte(byte)
  return byte ~= nil
    and ((byte >= 48 and byte <= 57) or (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122))
end

local function is_escaped(text, pos)
  local count = 0
  pos = pos - 1
  while pos >= 1 and text:byte(pos) == 92 do
    count = count + 1
    pos = pos - 1
  end
  return count % 2 == 1
end

local function underscore_can_delimit(text, opener, closer, len)
  local before_open = text:byte(opener - 1)
  local after_open = text:byte(opener + len)
  local before_close = text:byte(closer - 1)
  local after_close = text:byte(closer + len)
  if is_alnum_byte(before_open) and is_alnum_byte(after_open) then
    return false
  end
  if is_alnum_byte(before_close) and is_alnum_byte(after_close) then
    return false
  end
  return true
end

local function find_unescaped(text, needle, from, limit)
  local pos = from
  while pos <= limit do
    local found = text:find(needle, pos, true)
    if found == nil or found > limit then
      return nil
    end
    if not is_escaped(text, found) then
      return found
    end
    pos = found + #needle
  end
  return nil
end

local parse_inlines

local function find_closing_delimiter(text, delimiter, opener, from, limit)
  local pos = from
  while true do
    local found = find_unescaped(text, delimiter, pos, limit)
    if found == nil then
      return nil
    end
    if delimiter:sub(1, 1) ~= "_" or underscore_can_delimit(text, opener, found, #delimiter) then
      return found
    end
    pos = found + #delimiter
  end
end

local function push_text(tokens, text)
  if text == "" then
    return
  end
  local previous = tokens[#tokens]
  if previous ~= nil and previous.kind == "text" then
    previous.text = previous.text .. text
  else
    tokens[#tokens + 1] = { kind = "text", text = text }
  end
end

local function parse_delimiter(text, i)
  local triple = text:sub(i, i + 2)
  if triple == "***" or triple == "___" then
    return triple, "strong_emph"
  end
  local pair = text:sub(i, i + 1)
  if pair == "**" or pair == "__" then
    return pair, "strong"
  end
  if pair == "~~" then
    return pair, "delete"
  end
  local one = text:sub(i, i)
  if one == "*" or one == "_" then
    return one, "emph"
  end
  return nil
end

parse_inlines = function(text, first, last)
  local tokens = {}
  local i = first
  while i <= last do
    local ch = text:sub(i, i)

    if ch == "\\" and i < last then
      local next_ch = text:sub(i + 1, i + 1)
      if next_ch:match("[%[%]%(%)`*_~\\]") then
        push_text(tokens, next_ch)
        i = i + 2
      else
        push_text(tokens, ch)
        i = i + 1
      end
    elseif ch == "`" then
      local close = find_unescaped(text, "`", i + 1, last)
      if close ~= nil then
        tokens[#tokens + 1] = { kind = "code", text = text:sub(i + 1, close - 1) }
        i = close + 1
      else
        push_text(tokens, ch)
        i = i + 1
      end
    elseif ch == "[" then
      local close_label = find_unescaped(text, "]", i + 1, last)
      local open_url = close_label ~= nil and text:sub(close_label + 1, close_label + 1) == "("
      local close_url = open_url and find_unescaped(text, ")", close_label + 2, last) or nil
      if close_label ~= nil and close_url ~= nil then
        tokens[#tokens + 1] = {
          kind = "link",
          label = parse_inlines(text, i + 1, close_label - 1),
          url = text:sub(close_label + 2, close_url - 1),
        }
        i = close_url + 1
      else
        push_text(tokens, ch)
        i = i + 1
      end
    else
      local delimiter, kind = parse_delimiter(text, i)
      local close = delimiter ~= nil
          and find_closing_delimiter(text, delimiter, i, i + #delimiter, last)
        or nil
      if close ~= nil then
        tokens[#tokens + 1] = {
          kind = kind,
          children = parse_inlines(text, i + #delimiter, close - 1),
        }
        i = close + #delimiter
      elseif delimiter ~= nil then
        push_text(tokens, ch)
        i = i + 1
      else
        local start = i
        repeat
          i = i + 1
        until i > last or is_inline_syntax_byte(text:byte(i))
        push_text(tokens, text:sub(start, i - 1))
      end
    end
  end
  return tokens
end

local function render_tokens(tokens)
  local out = {}
  for _, token in ipairs(tokens or {}) do
    if token.kind == "text" then
      out[#out + 1] = token.text
    elseif token.kind == "code" then
      out[#out + 1] = ansi.color(PI_ACCENT, token.text)
    elseif token.kind == "link" then
      out[#out + 1] = ansi.color(PI_LINK, underline(render_tokens(token.label)))
        .. ansi.dim(" (" .. token.url .. ")")
    elseif token.kind == "strong" then
      out[#out + 1] = ansi.bold(render_tokens(token.children))
    elseif token.kind == "emph" then
      out[#out + 1] = italic(render_tokens(token.children))
    elseif token.kind == "strong_emph" then
      out[#out + 1] = ansi.bold(italic(render_tokens(token.children)))
    elseif token.kind == "delete" then
      out[#out + 1] = ansi.dim(render_tokens(token.children))
    end
  end
  return table.concat(out)
end

local function render_inline(text)
  text = tostring(text or "")
  if text == "" then
    return ""
  end
  return render_tokens(parse_inlines(text, 1, #text))
end

function M.parse_inline(text)
  text = tostring(text or "")
  return parse_inlines(text, 1, #text)
end

M.render_inline = render_inline

-- ---------- line-level renderer ----------

local function render_heading(text, level)
  local function apply(value)
    value = ansi.bold(value)
    if level == 1 then
      value = underline(value)
    end
    return ansi.color(PI_HEADING, value)
  end

  -- Inline spans emit a full SGR reset. Restore the heading's color and
  -- emphasis after each one so text following code, links, or emphasis keeps
  -- the heading style, matching pi's heading-specific inline style context.
  local restore = apply(""):gsub(RESET_PATTERN, "")
  if restore ~= "" then
    text = text:gsub(RESET_PATTERN, RESET .. restore)
  end
  return apply(text)
end

local function render_line(line, state)
  -- Code fence toggles: ``` or ~~~ at line start, optionally with lang.
  local fence = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
  if fence then
    state.in_code_fence = not state.in_code_fence
    return ansi.color(PI_GRAY, line)
  end
  if state.in_code_fence then
    return ansi.color(PI_GRAY, line)
  end

  -- Headers: # ... ######
  local hashes, rest = line:match("^(#+)%s+(.*)$")
  if hashes and #hashes <= 6 then
    local level = #hashes
    local prefix = level >= 3 and (hashes .. " ") or ""
    return render_heading(prefix .. render_inline(rest), level)
  end

  -- Horizontal rule
  if
    line:match("^%s*%-%-%-+%s*$")
    or line:match("^%s*%*%*%*+%s*$")
    or line:match("^%s*___+%s*$")
  then
    return ansi.color(PI_GRAY, line)
  end

  -- Bullet list: -, *, + (but not horizontal-rule-like)
  local indent, body = line:match("^(%s*)[%-%*%+]%s+(.*)$")
  if indent and body then
    return indent .. ansi.color(PI_ACCENT, "•") .. " " .. render_inline(body)
  end

  -- Numbered list
  local num_indent, num, num_body = line:match("^(%s*)(%d+%.)%s+(.*)$")
  if num then
    return num_indent .. ansi.color(PI_ACCENT, num) .. " " .. render_inline(num_body)
  end

  -- Blockquote
  local bq = line:match("^>%s?(.*)$")
  if bq then
    return ansi.color(PI_GRAY, "│ ") .. render_inline(bq)
  end

  -- Plain paragraph line
  return render_inline(line)
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

function M.render_line(line, in_code_fence)
  line = line or ""
  local key = (in_code_fence and "1|" or "0|") .. line
  local hit = cache[key]
  if hit ~= nil then
    return hit
  end

  local state = { in_code_fence = not not in_code_fence }
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
    pending = {},
    state = { in_code_fence = false },
  }
  function stream:feed(text)
    if type(text) ~= "string" or text == "" then
      return ""
    end
    local out = {}
    local start = 1
    while true do
      local nl = text:find("\n", start, true)
      if not nl then
        break
      end
      if nl > start then
        self.pending[#self.pending + 1] = text:sub(start, nl - 1)
      end
      local line = table.concat(self.pending)
      self.pending = {}
      out[#out + 1] = render_line(line, self.state) .. "\n"
      start = nl + 1
    end
    if start <= #text then
      self.pending[#self.pending + 1] = text:sub(start)
    end
    return table.concat(out)
  end
  function stream:flush()
    if #self.pending == 0 then
      return ""
    end
    local line = table.concat(self.pending)
    self.pending = {}
    return render_line(line, self.state)
  end
  return stream
end

return M
