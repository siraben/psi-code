-- psi.resources: prompt/context resource discovery.

local records = require("psi.records")
local prelude = require("psi.prelude")

local M = {}

local CONTEXT_FILENAMES = { "AGENTS.md", "CLAUDE.md" }
local diagnostics = {}

local function add_context(out, path, source)
  if psi.file_exists(path) then
    out[#out + 1] = records.new_context_file(path, psi.read_file(path))
    out[#out].source = source
  end
end

function M.diagnostics()
  local out = {}
  for i, d in ipairs(diagnostics) do out[i] = d end
  return out
end

function M.context_files()
  diagnostics = {}
  local found = {}
  local home = os.getenv("HOME")
  if home and home ~= "" then
    for _, name in ipairs(CONTEXT_FILENAMES) do
      add_context(found, prelude.path_join(home, ".config/psi/" .. name), "global")
    end
  end

  local dir = psi.cwd()
  local project = {}
  while true do
    local local_matches = {}
    for _, name in ipairs(CONTEXT_FILENAMES) do
      add_context(local_matches, prelude.path_join(dir, name), "project")
    end
    local merged = {}
    for _, f in ipairs(local_matches) do merged[#merged + 1] = f end
    for _, f in ipairs(project) do merged[#merged + 1] = f end
    project = merged
    local parent = psi.parent_directory(dir)
    if parent == dir then break end
    dir = parent
  end

  for _, f in ipairs(project) do found[#found + 1] = f end
  if psi.events then
    psi.events.emit("resources_discover", { context_files = found, diagnostics = diagnostics })
  end
  return found
end

return M
