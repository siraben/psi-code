-- psi.resources: prompt/context resource discovery.

local records = require("psi.records")
local prelude = require("psi.prelude")

local M = {}

local CONTEXT_FILENAMES = { "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD" }
local diagnostics = {}

local function add_context(out, path, source)
  if psi.file_exists(path) then
    out[#out + 1] = records.new_context_file(path, psi.read_file(path))
    out[#out].source = source
    return true
  end
  return false
end

local function add_first_context(out, dir, source)
  for _, name in ipairs(CONTEXT_FILENAMES) do
    if add_context(out, prelude.path_join(dir, name), source) then
      return true
    end
  end
  return false
end

local function config_dir()
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then
    return prelude.path_join(xdg, "psi")
  end
  local home = os.getenv("HOME")
  if home and home ~= "" then
    return prelude.path_join(home, ".config/psi")
  end
  return nil
end

function M.diagnostics()
  local out = {}
  for i, d in ipairs(diagnostics) do
    out[i] = d
  end
  return out
end

function M.context_files()
  diagnostics = {}
  local found = {}
  if psi.no_context_files then
    if psi.events then
      psi.events.emit("resources_discover", { context_files = found, diagnostics = diagnostics })
    end
    return found
  end

  local cfg = config_dir()
  if cfg then
    add_first_context(found, cfg, "global")
  end

  local dir = psi.cwd()
  local project = {}
  while true do
    local local_matches = {}
    add_first_context(local_matches, dir, "project")
    local merged = {}
    for _, f in ipairs(local_matches) do
      merged[#merged + 1] = f
    end
    for _, f in ipairs(project) do
      merged[#merged + 1] = f
    end
    project = merged
    local parent = psi.parent_directory(dir)
    if parent == dir then
      break
    end
    dir = parent
  end

  for _, f in ipairs(project) do
    found[#found + 1] = f
  end
  if psi.events then
    psi.events.emit("resources_discover", { context_files = found, diagnostics = diagnostics })
  end
  return found
end

local function first_existing(paths)
  for _, path in ipairs(paths) do
    if path and psi.file_exists(path) then
      return path, psi.read_file(path)
    end
  end
  return nil, nil
end

function M.system_prompt_file()
  local cfg = config_dir()
  local cwd = psi.cwd()
  return first_existing({
    -- Repo-controlled prompt overrides are honored only when trusted.
    psi.project_trusted and prelude.path_join(prelude.path_join(cwd, ".psi"), "SYSTEM.md") or nil,
    cfg and prelude.path_join(cfg, "SYSTEM.md") or nil,
  })
end

function M.append_system_prompt_file()
  local cfg = config_dir()
  local cwd = psi.cwd()
  return first_existing({
    psi.project_trusted and prelude.path_join(prelude.path_join(cwd, ".psi"), "APPEND_SYSTEM.md")
      or nil,
    cfg and prelude.path_join(cfg, "APPEND_SYSTEM.md") or nil,
  })
end

-- Skills are advertised by metadata only. The model reads SKILL.md with
-- the ordinary read tool when a task matches; scanning never executes code.
local function skill_metadata(path)
  if psi.file_type(path) ~= "file" then
    return nil
  end
  -- Frontmatter is small; avoid loading bundled reference material just to
  -- discover the skill. A header that exceeds this bound is ignored.
  local content = psi.read_file_prefix(path, 8192)
  if type(content) ~= "string" then
    return nil
  end
  content = content:gsub("^\239\187\191", ""):gsub("\r\n", "\n")
  local header = content:match("^%-%-%-\n(.-)\n%-%-%-\n") or content:match("^%-%-%-\n(.-)\n%-%-%-$")
  if not header then
    return nil
  end
  local fields = {}
  for line in (header .. "\n"):gmatch("([^\n]*)\n") do
    local key, value = line:match("^([%w%-]+):%s*(.-)%s*$")
    if key and value then
      if value:match('^".*"$') or value:match("^'.*'$") then
        value = value:sub(2, -2)
      end
      fields[key] = value
    end
  end
  local description = fields.description
  if not description or description == "" or #description > 1024 then
    return nil
  end
  local directory = psi.parent_directory(path)
  local name = fields.name or directory:match("([^/\\]+)$")
  if
    not name
    or #name > 64
    or name:find("--", 1, true)
    or not (name:match("^[a-z0-9]$") or name:match("^[a-z0-9][a-z0-9-]*[a-z0-9]$"))
  then
    return nil
  end
  return {
    name = name,
    description = description,
    path = path,
    directory = directory,
    disable_model_invocation = fields["disable-model-invocation"] == "true",
  }
end

local function scan_skill_dir(dir, out, seen_dirs, seen_names)
  if psi.file_type(dir) ~= "directory" then
    return
  end
  local canonical = psi.path_realpath and psi.path_realpath(dir) or dir
  if seen_dirs[canonical] then
    return
  end
  seen_dirs[canonical] = true

  local skill = skill_metadata(prelude.path_join(dir, "SKILL.md"))
  if skill then
    if not seen_names[skill.name] then
      out[#out + 1] = skill
      seen_names[skill.name] = true
    end
    return
  end

  local entries = psi.list_dir(dir) or {}
  table.sort(entries)
  for _, name in ipairs(entries) do
    if name:sub(1, 1) ~= "." and name ~= "node_modules" then
      local child = prelude.path_join(dir, name)
      if psi.file_type(child) == "directory" then
        scan_skill_dir(child, out, seen_dirs, seen_names)
      end
    end
  end
end

function M.skills()
  local found, seen_dirs, seen_names = {}, {}, {}
  local cfg = config_dir()
  if cfg then
    scan_skill_dir(prelude.path_join(cfg, "skills"), found, seen_dirs, seen_names)
  end
  if psi.project_trusted then
    local project_dir = prelude.path_join(prelude.path_join(psi.cwd(), ".psi"), "skills")
    scan_skill_dir(project_dir, found, seen_dirs, seen_names)
  end
  return found
end

return M
