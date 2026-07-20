-- psi.trust_manager: project-trust decisions for repo-local resources.
--
-- Ported from pi-mono's core/project-trust.ts + core/trust-manager.ts.
-- Project-local configuration (./.psi/settings.json, extensions, prompts,
-- keybindings, SYSTEM.md, APPEND_SYSTEM.md) is code/config supplied by the
-- checked-out repository, so it only loads when the project directory is
-- trusted. Trust state is keyed by the canonical project path and kept in
-- ~/.config/psi/trusted.json.
--
-- Resolution order (M.resolve):
--   1. PSI_TRUST env ("always"/"1" or "never"/"0")
--   2. no trust-requiring resources in cwd -> trusted (nothing to gate)
--   3. stored decision in trusted.json
--   4. default policy ("project_trust" in the *global* settings file):
--      "always" / "never" / "ask" (default)
--   5. interactive boot -> prompt once; otherwise -> untrusted
--
-- "y"/"n" answers apply to this session only; "always"/"never" persist.

local prelude = require("psi.prelude")
local path_util = require("psi.path_utils")

local M = {}

local GATED_RESOURCES = {
  ".psi/settings.json",
  ".psi/keybindings.json",
  ".psi/SYSTEM.md",
  ".psi/APPEND_SYSTEM.md",
  ".psi/extensions",
  ".psi/prompts",
}

local function config_dir()
  local home = os.getenv("HOME")
  if home and home ~= "" then
    return prelude.path_join(prelude.path_join(home, ".config"), "psi")
  end
  return nil
end

local function store_path()
  local dir = config_dir()
  return dir and prelude.path_join(dir, "trusted.json") or nil
end

local function canonical(path)
  local real = path_util.realpath(path)
  if real and real ~= "" then
    return real
  end
  return path_util.resolve(path) or path
end

local function read_store()
  local path = store_path()
  if not path or not psi.file_exists(path) then
    return {}
  end
  local parsed = prelude.safe_json_decode(psi.read_file(path), nil)
  return type(parsed) == "table" and parsed or {}
end

function M.get(cwd)
  local stored = read_store()[canonical(cwd)]
  if stored == true then
    return true
  end
  if stored == false then
    return false
  end
  return nil
end

function M.set(cwd, trusted)
  local path = store_path()
  if not path then
    return false
  end
  local data = read_store()
  data[canonical(cwd)] = trusted and true or false
  if not psi.mkdir_parent(path) then
    return false
  end
  return psi.file_write_secure(path, psi.json_encode(data))
end

-- List the gated resources that actually exist in `dir`. Only their
-- presence matters; contents are never read here.
function M.present_resources(dir)
  local found = {}
  for _, rel in ipairs(GATED_RESOURCES) do
    if psi.file_exists(path_util.join(dir, rel)) then
      found[#found + 1] = rel
    end
  end
  return found
end

function M.requires_prompt(cwd)
  return #M.present_resources(cwd) > 0
end

-- Default policy from the *global* settings only: the project file is
-- exactly what this decision gates, so it must not influence it.
local function default_policy()
  local dir = config_dir()
  if dir then
    local path = prelude.path_join(dir, "settings.json")
    if psi.file_exists(path) then
      local parsed = prelude.safe_json_decode(psi.read_file(path), nil)
      local value = type(parsed) == "table" and parsed.project_trust or nil
      if type(value) == "table" then
        value = value.default
      end
      if value == "always" or value == "never" or value == "ask" then
        return value
      end
    end
  end
  return "ask"
end

local function env_override()
  local env = os.getenv("PSI_TRUST")
  if env == "always" or env == "1" then
    return true
  end
  if env == "never" or env == "0" then
    return false
  end
  return nil
end

local function ask(cwd, resources)
  io.stderr:write("Trust project folder?\n" .. cwd .. "\n\n")
  io.stderr:write(
    "This allows psi to load "
      .. table.concat(resources, ", ")
      .. ",\n"
      .. "which a malicious repository can use to execute code as you.\n"
      .. "[y]es, once / [n]o / [a]lways / n[e]ver: "
  )
  local answer = prelude.trim(string.lower(io.read("*l") or ""))
  if answer == "a" or answer == "always" then
    M.set(cwd, true)
    return true
  end
  if answer == "e" or answer == "never" then
    M.set(cwd, false)
    return false
  end
  return answer == "y" or answer == "yes"
end

-- Resolve the trust decision for the current working directory.
-- `interactive` should be true only for REPL/TUI boots attached to a
-- terminal; anything else resolves to untrusted instead of prompting.
function M.resolve(interactive)
  local override = env_override()
  if override ~= nil then
    return override
  end
  local cwd = psi.cwd()
  local resources = M.present_resources(cwd)
  if #resources == 0 then
    return true
  end
  local stored = M.get(cwd)
  if stored ~= nil then
    return stored
  end
  local policy = default_policy()
  if policy == "always" then
    return true
  end
  if policy == "never" then
    return false
  end
  if interactive then
    return ask(cwd, resources)
  end
  io.stderr:write(
    "psi: project "
      .. cwd
      .. " is not trusted; skipping "
      .. table.concat(resources, ", ")
      .. " (start psi interactively to be asked, or set PSI_TRUST=always)\n"
  )
  return false
end

return M
