-- psi.skills: lightweight Agent Skills-style discovery for psi.
--
-- Skills are directories containing SKILL.md. psi only keeps the
-- name/description/path in steady-state context; the full file is loaded
-- on demand by the model through the read tool or explicitly via the
-- /skill:name slash command.

local prelude = require("psi.prelude")

local M = {}

local loaded = {}

local function trim(text)
  if type(text) ~= "string" then
    return ""
  end
  return prelude.trim(text)
end

local function strip_quotes(text)
  if type(text) ~= "string" then
    return text
  end
  return text:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1")
end

local function parse_frontmatter(raw)
  local fm, body = {}, raw
  if type(raw) ~= "string" or raw:sub(1, 3) ~= "---" then
    return fm, body
  end
  local rest = raw:sub(4)
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
  after = after:gsub("^\n%-%-%-\r?\n?", "")
  for line in (header .. "\n"):gmatch("([^\n]*)\n") do
    local k, v = line:match("^%s*([%w%-_]+)%s*:%s*(.-)%s*$")
    if k then
      fm[k] = strip_quotes(v)
    end
  end
  return fm, after
end

local function basename(path)
  if type(path) ~= "string" or path == "" then
    return ""
  end
  return path:match("([^/]+)$") or path
end

local function escape_xml(text)
  return tostring(text or "")
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
    :gsub("'", "&apos;")
end

local function normalize_root(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local expanded = psi.path_expand(path)
  if not expanded or expanded == "" then
    return nil
  end
  local resolved = psi.path_resolve(expanded)
  if psi.file_type(resolved) ~= "directory" then
    return nil
  end
  return resolved
end

local function append_root(roots, seen, path)
  local root = normalize_root(path)
  if not root or seen[root] then
    return
  end
  seen[root] = true
  roots[#roots + 1] = root
end

local function ordered_project_dirs()
  local chain = {}
  local dir = psi.cwd()
  while true do
    chain[#chain + 1] = dir
    local parent = psi.parent_directory(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  local ordered = {}
  for i = #chain, 1, -1 do
    ordered[#ordered + 1] = chain[i]
  end
  return ordered
end

local function discovery_roots()
  local roots, seen = {}, {}
  local env_dirs = os.getenv("PSI_SKILLS_DIR") or ""
  for dir in (env_dirs .. ":"):gmatch("([^:]*):") do
    if dir ~= "" then
      append_root(roots, seen, dir)
    end
  end

  local home = os.getenv("HOME")
  if home and home ~= "" then
    append_root(roots, seen, prelude.path_join(home, ".config/psi/skills"))
    append_root(roots, seen, prelude.path_join(home, ".agents/skills"))
    append_root(roots, seen, prelude.path_join(home, ".codex/skills"))
  end

  for _, dir in ipairs(ordered_project_dirs()) do
    append_root(roots, seen, prelude.path_join(dir, ".agents/skills"))
    append_root(roots, seen, prelude.path_join(dir, ".psi/skills"))
  end

  return roots
end

local function load_skill_file(path)
  local raw = prelude.safe_read(path)
  if not raw then
    return nil
  end
  local fm = {}
  local body = raw
  fm, body = parse_frontmatter(raw)
  local description = trim(fm.description)
  if description == "" then
    return nil
  end
  local base_dir = psi.parent_directory(path)
  local name = trim(fm.name)
  if name == "" then
    name = basename(base_dir)
  end
  return {
    name = name,
    description = description,
    file_path = path,
    base_dir = base_dir,
    body = trim(body),
    disable_model_invocation = tostring(fm["disable-model-invocation"] or "") == "true",
  }
end

local function load_from_root(root, out)
  if psi.file_type(root) ~= "directory" then
    return
  end
  local skill_file = prelude.path_join(root, "SKILL.md")
  if psi.file_type(skill_file) == "file" then
    local skill = load_skill_file(skill_file)
    if skill then
      out[#out + 1] = skill
    end
    return
  end
  local entries = psi.list_dir(root)
  if type(entries) ~= "table" then
    return
  end
  table.sort(entries)
  for _, name in ipairs(entries) do
    if type(name) == "string" and name:sub(1, 1) ~= "." then
      local path = prelude.path_join(root, name)
      if psi.file_type(path) == "directory" then
        load_from_root(path, out)
      end
    end
  end
end

local function copy_skill(skill)
  return {
    name = skill.name,
    description = skill.description,
    file_path = skill.file_path,
    base_dir = skill.base_dir,
    disable_model_invocation = skill.disable_model_invocation and true or false,
  }
end

function M.load()
  local ordered = {}
  local by_name = {}
  for _, root in ipairs(discovery_roots()) do
    local found = {}
    load_from_root(root, found)
    for _, skill in ipairs(found) do
      by_name[skill.name] = skill
    end
  end
  for _, skill in pairs(by_name) do
    ordered[#ordered + 1] = skill
  end
  table.sort(ordered, function(a, b)
    return a.name < b.name
  end)
  loaded = ordered
  return M.list()
end

function M.list()
  local out = {}
  for i, skill in ipairs(loaded) do
    out[i] = copy_skill(skill)
  end
  return out
end

function M.find(name)
  for _, skill in ipairs(loaded) do
    if skill.name == name then
      return copy_skill(skill)
    end
  end
  return nil
end

function M.prompt_section()
  local visible = {}
  for _, skill in ipairs(loaded) do
    if not skill.disable_model_invocation then
      visible[#visible + 1] = skill
    end
  end
  if #visible == 0 then
    return ""
  end
  local lines = {
    "\n\nThe following skills provide specialized instructions for specific tasks.",
    "Use the read tool to load a skill's file when the task matches its description.",
    "When a skill file references a relative path, resolve it against the skill directory and use an absolute path in tool commands.",
    "",
    "<available_skills>",
  }
  for _, skill in ipairs(visible) do
    lines[#lines + 1] = "  <skill>"
    lines[#lines + 1] = "    <name>" .. escape_xml(skill.name) .. "</name>"
    lines[#lines + 1] = "    <description>" .. escape_xml(skill.description) .. "</description>"
    lines[#lines + 1] = "    <location>" .. escape_xml(skill.file_path) .. "</location>"
    lines[#lines + 1] = "  </skill>"
  end
  lines[#lines + 1] = "</available_skills>"
  return table.concat(lines, "\n")
end

function M.expand(text)
  if type(text) ~= "string" or not prelude.starts_with(text, "/skill:") then
    return nil
  end
  local space = text:find(" ", 1, true)
  local name, args
  if space then
    name = text:sub(8, space - 1)
    args = trim(text:sub(space + 1))
  else
    name = text:sub(8)
    args = ""
  end
  if name == "" then
    return nil
  end
  for _, skill in ipairs(loaded) do
    if skill.name == name then
      local skill_block = table.concat({
        '<skill name="',
        escape_xml(skill.name),
        '" location="',
        escape_xml(skill.file_path),
        '">\nReferences are relative to ',
        escape_xml(skill.base_dir),
        ".\n\n",
        skill.body,
        "\n</skill>",
      })
      return args ~= "" and (skill_block .. "\n\n" .. args) or skill_block
    end
  end
  return nil
end

function M.help_lines()
  local visible = M.list()
  if #visible == 0 then
    return nil
  end
  local buf = {
    "skills (`/skill:name`, discovered from PSI_SKILLS_DIR, ~/.config/psi/skills, ~/.agents/skills, ~/.codex/skills, ./.agents/skills, and ./.psi/skills):\n",
  }
  for _, skill in ipairs(visible) do
    buf[#buf + 1] = "  /skill:" .. skill.name .. " [args]"
    if skill.description ~= "" then
      buf[#buf + 1] = "  - " .. skill.description
    end
    buf[#buf + 1] = "\n"
  end
  return table.concat(buf)
end

return M
