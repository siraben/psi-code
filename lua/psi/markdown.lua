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
