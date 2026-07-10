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
    prelude.path_join(prelude.path_join(cwd, ".psi"), "SYSTEM.md"),
    cfg and prelude.path_join(cfg, "SYSTEM.md") or nil,
  })
end

function M.append_system_prompt_file()
  local cfg = config_dir()
  local cwd = psi.cwd()
  return first_existing({
    prelude.path_join(prelude.path_join(cwd, ".psi"), "APPEND_SYSTEM.md"),
    cfg and prelude.path_join(cfg, "APPEND_SYSTEM.md") or nil,
  })
end

return M
