-- psi.credential: resolve auth-file secret values.
--
-- API-key entries in auth.json may store the key literally or as a
-- reference that is resolved at use time, matching pi-mono's credential
-- handling:
--
--   * "$VAR" / "${VAR}"  -> substituted from the process environment
--                           (embedded occurrences are interpolated too)
--   * "!some command"    -> the shell command after `!` is run and its
--                           trimmed stdout becomes the secret; results
--                           are cached per-process so a command that
--                           mints a short-lived token runs once
--   * anything else       -> used verbatim
--
-- Keeping this separate from psi.auth_storage lets the resolution rules
-- be unit-tested without touching the on-disk auth.json.

local prelude = require("psi.prelude")

local M = {}

-- Per-process cache for `!shell-command` resolution, keyed by the raw
-- command string. A successful run stores its trimmed stdout; a failed
-- run stores `false` so we neither retry nor treat it as a hit. This
-- mirrors pi's behaviour where a credential command runs at most once
-- per process.
local shell_cache = {}

-- Exposed for tests that need a clean slate between cases.
function M._reset_cache()
  shell_cache = {}
end

local function resolve_shell(command)
  command = prelude.trim(command or "")
  if command == "" then
    return nil
  end
  local cached = shell_cache[command]
  if cached ~= nil then
    return cached or nil
  end
  local value = nil
  if psi and type(psi.process_run) == "function" then
    local ok, result = pcall(psi.process_run, command)
    if ok and type(result) == "table" then
      local status = result.status
      -- Treat a missing status as success: some hosts only populate it
      -- on failure. A non-zero status means the command failed and its
      -- stdout must not be trusted as a credential.
      if status == nil or status == 0 then
        local out = prelude.trim(result.output or "")
        if out ~= "" then
          value = out
        end
      end
    end
  end
  shell_cache[command] = value or false
  return value
end

local function interpolate_env(value)
  -- ${VAR} first so a longer braced form isn't partially matched by the
  -- bare-$ pass. Unset variables collapse to empty string, matching
  -- POSIX shell expansion (and pi).
  value = value:gsub("%${([%w_]+)}", function(name)
    return os.getenv(name) or ""
  end)
  value = value:gsub("%$([%w_]+)", function(name)
    return os.getenv(name) or ""
  end)
  return value
end

-- Resolve a raw auth-file secret string to its effective value, or nil
-- when it resolves to nothing (empty, failed command, unset var alone).
function M.resolve(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  if value:sub(1, 1) == "!" then
    return resolve_shell(value:sub(2))
  end
  local resolved = interpolate_env(value)
  if resolved == "" then
    return nil
  end
  return resolved
end

return M
