-- psi.trust: workspace trust for project-local resources.
--
-- A checkout can ship ./.psi/extensions (code executed at startup),
-- ./.psi/settings.json (provider/model defaults), ./.psi/SYSTEM.md and
-- APPEND_SYSTEM.md (system prompt control), ./.psi/skills, ./.psi/prompts and
-- keybindings.json. Loading these unconditionally turns `cd evil-repo
-- && psi` into silent code execution, so they stay disabled until the
-- directory is trusted. Trust decisions are kept in
-- ~/.config/psi/trust.json keyed by canonical directory, inherited from
-- the nearest ancestor with a stored decision.

local prelude = require("psi.prelude")

local M = {}

local RESOURCE_NAMES = {
  "settings.json",
  "extensions",
  "prompts",
  "skills",
  "SYSTEM.md",
  "APPEND_SYSTEM.md",
  "keybindings.json",
}

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

local function store_path()
  local dir = config_dir()
  return dir and prelude.path_join(dir, "trust.json") or nil
end

local function canonical(dir)
  local real = psi.path_realpath(dir)
  if real and real ~= "" then
    return real
  end
  return dir
end

local function load_store()
  local path = store_path()
  if not path or not psi.file_exists(path) then
    return {}
  end
  local parsed = prelude.safe_json_decode(psi.read_file(path), nil)
  if type(parsed) ~= "table" then
    return {}
  end
  return parsed
end

local function save_store(store)
  local path = store_path()
  if not path then
    return false, "could not locate the trust store"
  end
  if not psi.mkdir_parent(path) then
    return false, "could not create the trust store directory"
  end
  local encoded_ok, encoded = pcall(psi.json_encode, store)
  if not encoded_ok or type(encoded) ~= "string" then
    return false, "could not encode the trust store"
  end
  if not psi.file_write_secure(path, encoded) then
    return false, "could not write " .. path
  end
  return true
end

-- Nearest stored decision for dir or any ancestor; nil when none.
function M.stored(dir)
  dir = canonical(dir)
  local store = load_store()
  while true do
    local decision = store[dir]
    if type(decision) == "boolean" then
      return decision
    end
    local parent = psi.parent_directory(dir)
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

function M.remember(dir, trusted)
  local store = load_store()
  store[canonical(dir)] = trusted and true or false
  return save_store(store)
end

function M.has_project_resources(dir)
  local dotpsi = prelude.path_join(dir, ".psi")
  for _, name in ipairs(RESOURCE_NAMES) do
    if psi.file_exists(prelude.path_join(dotpsi, name)) then
      return true
    end
  end
  return false
end

-- The fallback policy comes only from the global settings layer; a
-- repo-local settings file must never decide its own trust.
local function default_policy()
  local dir = config_dir()
  if not dir then
    return "ask"
  end
  local parsed = prelude.safe_json_decode(
    psi.file_exists(prelude.path_join(dir, "settings.json"))
        and psi.read_file(prelude.path_join(dir, "settings.json"))
      or nil,
    nil
  )
  local policy = type(parsed) == "table"
    and parsed.security
    and parsed.security.default_project_trust
  if policy == "always" or policy == "never" then
    return policy
  end
  return "ask"
end

local function prompt(cwd)
  io.stderr:write("psi: this directory contains .psi resources (extensions, settings, prompts)\n")
  io.stderr:write("psi: trust " .. cwd .. "? [y] always / [s] session / [n] never: ")
  local line = io.read("l")
  if line == "y" or line == "Y" then
    local ok, err = M.remember(cwd, true)
    if not ok then
      io.stderr:write("psi: warning: " .. err .. "; trusting for this session only\n")
    end
    return true
  end
  if line == "s" or line == "S" then
    return true
  end
  if line == "n" or line == "N" then
    local ok, err = M.remember(cwd, false)
    if not ok then
      io.stderr:write("psi: warning: " .. err .. "; denial applies to this session only\n")
    end
  end
  return false
end

-- Resolve trust for the current working directory. Precedence:
-- --trust/--no-trust, PSI_TRUST, stored decision, implicit trust when
-- the directory has no .psi resources, the global default policy, an
-- interactive prompt, and finally deny.
function M.resolve(opts)
  opts = type(opts) == "table" and opts or {}
  local cwd = psi.cwd()
  if type(psi.trust_override) == "boolean" then
    return psi.trust_override
  end
  local env = os.getenv("PSI_TRUST")
  if env == "always" then
    return true
  elseif env == "never" then
    return false
  end
  local stored = M.stored(cwd)
  if stored ~= nil then
    return stored
  end
  if not M.has_project_resources(cwd) then
    return true
  end
  local policy = default_policy()
  if policy == "always" then
    return true
  elseif policy == "never" then
    return false
  end
  if not opts.interactive then
    return false
  end
  return prompt(canonical(cwd))
end

-- One-line notice when project resources exist but were skipped.
function M.notice_if_skipped()
  if not M.has_project_resources(psi.cwd()) then
    return
  end
  io.stderr:write(
    "psi: .psi resources skipped (use --trust now or /trust always for future sessions)\n"
  )
end

return M
