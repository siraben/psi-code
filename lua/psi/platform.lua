-- psi.platform: small host-shape helpers used by portable Lua tools.

local M = {}

local function env_nonempty(name)
  local value = os.getenv(name)
  return value ~= nil and value ~= ""
end

local function env_lower(name)
  local value = os.getenv(name)
  return value and value:lower() or ""
end

local function env_bool(name)
  local value = env_lower(name)
  if value == "1" or value == "on" or value == "true" or value == "yes" then
    return true
  end
  if value == "0" or value == "off" or value == "false" or value == "no" then
    return false
  end
  return nil
end

local function runtime_cwd()
  if type(psi) == "table" and type(psi.runtime_info) == "function" then
    local ok, info = pcall(psi.runtime_info)
    if ok and type(info) == "table" then
      return info["current-working-directory"]
    end
  end
  return nil
end

local function detect_windows()
  if os.getenv("OS") == "Windows_NT" then
    return true
  end
  if package.config and package.config:sub(1, 1) == "\\" then
    return true
  end
  local cwd = runtime_cwd()
  if cwd == nil and type(psi) == "table" and type(psi.cwd) == "function" then
    cwd = psi.cwd()
  end
  cwd = cwd or ""
  return cwd:match("^/[A-Za-z]/") ~= nil
end

-- The host shape can't change mid-process; memoize the detection so
-- hot paths (shell_argv, path mapping) don't re-read the environment.
local is_windows_cached = nil

function M.is_windows()
  if is_windows_cached == nil then
    is_windows_cached = detect_windows()
  end
  return is_windows_cached
end

function M.windows_ansi_supported()
  if not M.is_windows() then
    return true
  end

  local forced = env_bool("PSI_ANSI")
  if forced ~= nil then
    return forced
  end

  if env_nonempty("WT_SESSION") or env_nonempty("ANSICON") or env_nonempty("MSYSTEM") then
    return true
  end
  local term_program = env_lower("TERM_PROGRAM")
  if term_program:match("mintty") then
    return true
  end
  local conemu = env_lower("ConEmuANSI")
  if conemu == "on" or conemu == "1" or conemu == "true" then
    return true
  end

  local term = env_lower("TERM")
  if term ~= "" and term ~= "dumb" then
    if term:match("cygwin") ~= nil or term:match("msys") ~= nil or term:match("mintty") ~= nil then
      return true
    end
  end

  return true
end

function M.to_host_path(path)
  if type(path) ~= "string" then
    return path
  end
  if not M.is_windows() then
    return path
  end
  local drive, rest = path:match("^/([A-Za-z])/(.*)$")
  if drive then
    return drive:upper() .. ":\\" .. rest:gsub("/", "\\")
  end
  return path:gsub("/", "\\")
end

function M.from_host_path(path)
  if type(path) ~= "string" then
    return path
  end
  if not M.is_windows() then
    return path
  end
  local drive, rest = path:match("^([A-Za-z]):[\\/]*(.*)$")
  if drive then
    return "/" .. drive:upper() .. "/" .. rest:gsub("\\", "/")
  end
  return path:gsub("\\", "/")
end

local function trim_trailing_separators(path)
  while #path > 3 and (path:sub(-1) == "\\" or path:sub(-1) == "/") do
    path = path:sub(1, -2)
  end
  return path
end

function M.native_cwd()
  local cwd = runtime_cwd()
  if cwd == nil and type(psi) == "table" and type(psi.cwd) == "function" then
    cwd = psi.cwd()
  end
  return M.to_host_path(cwd or "")
end

function M.shell_name()
  if M.is_windows() then
    return "cmd.exe"
  end
  return "sh"
end

local function trim_spaces(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_cmd_comment_line(line)
  local trimmed = trim_spaces(line)
  if trimmed == "" then
    return true
  end
  if trimmed:sub(1, 2) == "::" then
    return true
  end
  local lower = trimmed:lower()
  return lower == "rem" or lower:match("^rem%s") ~= nil
end

local function ends_with_cmd_continuation(line)
  local stripped = line:gsub("%s+$", "")
  local carets = stripped:match("(%^+)$")
  return carets ~= nil and (#carets % 2) == 1
end

local function normalize_windows_cmd_script(command)
  if not command:find("[\r\n]") then
    return command
  end

  command = command:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  for line in (command .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  local logical = {}
  local pending = nil
  for _, line in ipairs(lines) do
    if pending ~= nil then
      pending = pending .. line
    else
      pending = line
    end

    if ends_with_cmd_continuation(pending) then
      pending = pending:gsub("%s+$", ""):sub(1, -2)
    else
      if not is_cmd_comment_line(pending) then
        logical[#logical + 1] = pending
      end
      pending = nil
    end
  end
  if pending ~= nil and not is_cmd_comment_line(pending) then
    logical[#logical + 1] = pending
  end

  if #logical == 0 then
    return "rem"
  end
  return table.concat(logical, " & ")
end

function M.shell_argv(command)
  if type(command) ~= "string" then
    return nil
  end
  if M.is_windows() then
    return { "cmd.exe", "/d", "/c", normalize_windows_cmd_script(command) }
  end
  return nil
end

function M.host_context_lines()
  local lines = {}
  if M.is_windows() then
    lines[#lines + 1] = "Host OS: Windows"
    lines[#lines + 1] = "Native cwd: " .. M.native_cwd()
    lines[#lines + 1] = "Shell tool backend: cmd.exe /d /c"
    lines[#lines + 1] = "Use Windows command syntax and native paths in shell commands."
  else
    lines[#lines + 1] = "Host OS: POSIX-like"
    lines[#lines + 1] = "Native cwd: " .. M.native_cwd()
    lines[#lines + 1] = "Shell tool backend: sh -lc"
  end
  return lines
end

function M.tempfile_path(prefix, suffix)
  prefix = prefix or "psi-"
  suffix = suffix or ""
  if not M.is_windows() then
    local path = psi.tempfile_path(prefix)
    return suffix ~= "" and (path .. suffix) or path
  end

  local dir = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP")
  if not dir or dir == "" then
    dir = M.to_host_path(psi.tempfile_path(""))
    dir = dir:gsub("[/\\][^/\\]*$", "")
  end
  dir = trim_trailing_separators(dir)
  local pid = tostring(os.getenv("PROCESS_ID") or "0")
  local stamp = tostring(psi.time_ms and psi.time_ms() or os.time())
  local name = prefix .. stamp .. "-" .. pid .. "-" .. tostring(math.random(1000000)) .. suffix
  return dir .. "\\" .. name
end

return M
