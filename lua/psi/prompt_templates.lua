-- psi.prompt_templates: user-authored slash commands.
--
-- Drop a `.md` file in $PSI_PROMPTS_DIR (colon-separated list),
-- $XDG_CONFIG_HOME/psi/prompts/ (fallback $HOME/.config/psi/prompts/),
-- or ./.psi/prompts/ and typing `/<filename> args…` in the REPL / TUI
-- expands the body (with bash-style argument substitution) and sends
-- it as the user's next turn.
--
-- Frontmatter (optional, between leading `---` lines):
--   description:   one-liner shown in /help
--   argument-hint: hint shown after /name in help (e.g. "[path]")
--
-- Argument substitution (run on the template body, not on the args):
--   $1, $2, …        positional arg (1-indexed; "" if absent)
--   $@, $ARGUMENTS   all args joined by a single space
--   ${@:N}           args from position N onwards (bash-style)
--   ${@:N:L}         L args starting from N
--
-- Ported from pi-mono (MIT, (c) 2025 Mario Zechner),
-- packages/coding-agent/src/core/prompt-templates.ts.

local prelude = require("psi.prelude")

local M = {}

local templates = {}
local enabled = true

local function parse_command_args(argsString)
  -- bash-ish: respect single and double quotes, split on whitespace.
  local args = {}
  local current = {}
  local in_quote = nil
  for i = 1, #argsString do
    local ch = argsString:sub(i, i)
    if in_quote then
      if ch == in_quote then
        in_quote = nil
      else
        current[#current + 1] = ch
      end
    elseif ch == '"' or ch == "'" then
      in_quote = ch
    elseif ch == " " or ch == "\t" then
      if #current > 0 then
        args[#args + 1] = table.concat(current)
        current = {}
      end
    else
      current[#current + 1] = ch
    end
  end
  if #current > 0 then
    args[#args + 1] = table.concat(current)
  end
  return args
end

local function substitute_args(content, args)
  local result = content

  -- $1, $2, ... first (before $@-family) so that wildcard expansions
  -- whose values contain $<digit> don't re-substitute.
  result = result:gsub("%$(%d+)", function(num)
    local idx = tonumber(num)
    return args[idx] or ""
  end)

  -- ${@:N:L} and ${@:N}
  result = result:gsub("%${@:(%d+):(%d+)}", function(startStr, lenStr)
    local start = tonumber(startStr) or 1
    if start < 1 then
      start = 1
    end
    local len = tonumber(lenStr) or 0
    local slice = {}
    for i = start, start + len - 1 do
      if args[i] then
        slice[#slice + 1] = args[i]
      end
    end
    return table.concat(slice, " ")
  end)
  result = result:gsub("%${@:(%d+)}", function(startStr)
    local start = tonumber(startStr) or 1
    if start < 1 then
      start = 1
    end
    local slice = {}
    for i = start, #args do
      slice[#slice + 1] = args[i]
    end
    return table.concat(slice, " ")
  end)

  local all_args = table.concat(args, " ")
  result = result:gsub("%$ARGUMENTS", all_args)
  result = result:gsub("%$@", all_args)

  return result
end

-- Minimal frontmatter parser: if the content starts with `---`,
-- consume lines until the next `---` and parse each as `key: value`.
-- Values are returned as strings (no YAML type inference).
local function parse_frontmatter(raw)
  local fm, body = {}, raw
  if raw:sub(1, 3) ~= "---" then
    return fm, body
  end
  local rest = raw:sub(4)
  -- Skip an optional newline immediately after the opener.
  if rest:sub(1, 1) == "\n" then
    rest = rest:sub(2)
  elseif rest:sub(1, 2) == "\r\n" then
    rest = rest:sub(3)
  end
  local close_idx = rest:find("\n%-%-%-\r?\n") or rest:find("\n%-%-%-$")
  if close_idx == nil then
    return fm, body
  end
  local header = rest:sub(1, close_idx - 1)
  local after = rest:sub(close_idx)
  -- Strip the closing `---` + optional newline.
  after = after:gsub("^\n%-%-%-\r?\n?", "")
  for line in (header .. "\n"):gmatch("([^\n]*)\n") do
    local k, v = line:match("^%s*([%w%-_]+)%s*:%s*(.-)%s*$")
    if k then
      -- Strip one layer of surrounding quotes for convenience.
      v = v:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
      fm[k] = v
    end
  end
  return fm, after
end

local function list_markdown_files(dir)
  if not dir or dir == "" then
    return {}
  end
  if not psi.file_exists(dir) then
    return {}
  end
  local entries = psi.list_dir(dir)
  if type(entries) ~= "table" then
    return {}
  end
  local out = {}
  for _, name in ipairs(entries) do
    if type(name) == "string" and name:match("%.md$") then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local function load_template_file(path, name)
  local raw = prelude.safe_read(path)
  if not raw then
    return false
  end
  local fm, body = parse_frontmatter(raw)
  local stem = name or path:match("([^/]+)%.md$") or path:match("([^/]+)$") or "template"
  local desc = fm.description
  if not desc or desc == "" then
    local first = body:match("([^\n]+)")
    if first then
      desc = prelude.trim(first):sub(1, 60)
    end
  end
  templates[stem] = {
    name = stem,
    description = desc or "",
    argument_hint = fm["argument-hint"],
    content = body,
    path = path,
  }
  return true
end

local function load_from_dir(dir)
  for _, name in ipairs(list_markdown_files(dir)) do
    local path = prelude.path_join(dir, name)
    load_template_file(path, name:gsub("%.md$", ""))
  end
end

local version = 0
local sorted_cache = nil
local sorted_cache_version = -1

function M.load()
  templates = {}
  if not enabled then
    version = version + 1
    return
  end
  version = version + 1
  local env_dirs = os.getenv("PSI_PROMPTS_DIR") or ""
  for dir in (env_dirs .. ":"):gmatch("([^:]*):") do
    if dir ~= "" then
      load_from_dir(dir)
    end
  end
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then
    load_from_dir(prelude.path_join(xdg, "psi/prompts"))
  else
    local home = os.getenv("HOME")
    if home and home ~= "" then
      load_from_dir(prelude.path_join(home, ".config/psi/prompts"))
    end
  end
  if psi.project_trusted then
    load_from_dir("./.psi/prompts")
  end
end

function M.clear()
  templates = {}
  version = version + 1
end

function M.set_enabled(value)
  enabled = value ~= false
  if not enabled then
    M.clear()
  end
end

function M.load_path(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  if psi.file_exists(path) then
    local entries = psi.list_dir(path)
    if type(entries) == "table" then
      load_from_dir(path)
      version = version + 1
      return true
    end
    if path:match("%.md$") then
      local ok = load_template_file(path)
      if ok then
        version = version + 1
      end
      return ok
    end
  end
  return false
end

function M.version()
  return version
end

function M.list()
  if sorted_cache and sorted_cache_version == version then
    return sorted_cache
  end
  local out = {}
  for _, t in pairs(templates) do
    out[#out + 1] = t
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  sorted_cache = out
  sorted_cache_version = version
  return out
end

function M.find(name)
  return templates[name]
end

-- If `text` is `/name [args]` and `name` matches a loaded template,
-- return the expanded body as a string. Returns nil otherwise —
-- callers should treat nil as "not a template; fall through".
function M.expand(text)
  if type(text) ~= "string" or text:sub(1, 1) ~= "/" then
    return nil
  end
  local space = text:find(" ", 1, true)
  local name, argsString
  if space then
    name = text:sub(2, space - 1)
    argsString = text:sub(space + 1)
  else
    name = text:sub(2)
    argsString = ""
  end
  local tmpl = templates[name]
  if not tmpl then
    return nil
  end
  return substitute_args(tmpl.content, parse_command_args(argsString))
end

-- Short multi-line listing for /help integration.
function M.help_lines()
  local list = M.list()
  if #list == 0 then
    return nil
  end
  local buf = { "prompt templates (drop .md in ~/.config/psi/prompts/):\n" }
  for _, t in ipairs(list) do
    local hint = t.argument_hint and (" " .. t.argument_hint) or ""
    buf[#buf + 1] = "  /" .. t.name .. hint
    if t.description ~= "" then
      buf[#buf + 1] = "  - " .. t.description
    end
    buf[#buf + 1] = "\n"
  end
  return table.concat(buf)
end

return M
