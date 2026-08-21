-- psi.clipboard: shared clipboard backends for slash commands and TUI.

local settings = require("psi.settings_manager")
local base64 = require("psi.base64")
local platform = require("psi.platform")

local M = {}

local CONFIG_ENABLED = "extensions.osc52_clipboard.enabled"
local CONFIG_TARGET = "extensions.osc52_clipboard.target"
local CONFIG_TMUX_PASSTHROUGH = "extensions.osc52_clipboard.tmux_passthrough"
local CONFIG_MAX_BYTES = "extensions.osc52_clipboard.max_bytes"

local DEFAULT_ENABLED = true
local DEFAULT_TARGET = "c"
local DEFAULT_TMUX_PASSTHROUGH = true
local DEFAULT_MAX_BYTES = 100000
local DEFAULT_READ_TIMEOUT_MS = 5000

local ENV_TMUX = "TMUX"

local ESC = string.char(27)
local BEL = string.char(7)
local ST = ESC .. "\\"
local OSC52_PREFIX = ESC .. "]52;"
local TMUX_DCS_PREFIX = ESC .. "Ptmux;" .. ESC
local TMUX_DCS_SUFFIX = ST

local CLIPBOARD_CMDS = {
  { name = "xclip", cmd = "xclip -selection clipboard" },
  { name = "pbcopy", cmd = "pbcopy" },
  { name = "wl-copy", cmd = "wl-copy" },
  { name = "xsel", cmd = "xsel --clipboard --input" },
}

local READ_CLIPBOARD_CMDS = {
  termux = { name = "termux-clipboard-get", argv = { "termux-clipboard-get" } },
  wayland = {
    name = "wl-paste",
    argv = { "wl-paste", "--no-newline", "--type", "text" },
  },
  xclip = {
    name = "xclip",
    argv = { "xclip", "-selection", "clipboard", "-out" },
  },
  xsel = {
    name = "xsel",
    argv = { "xsel", "--clipboard", "--output" },
  },
  macos = { name = "pbpaste", argv = { "pbpaste" } },
  windows = {
    name = "powershell",
    argv = {
      "powershell.exe",
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); "
        .. "$text = Get-Clipboard -Raw -Format Text; "
        .. "if ($null -ne $text) { [Console]::Out.Write($text) }",
    },
  },
}

local function context_env(context, name)
  if type(context.env) == "table" then
    return context.env[name]
  end
  return os.getenv(name)
end

local function env_nonempty(context, name)
  local value = context_env(context, name)
  return value ~= nil and value ~= ""
end

local function read_backends(context)
  local backends = {}
  local windows = context.is_windows
  if windows == nil then
    windows = platform.is_windows()
  end
  if windows then
    return { READ_CLIPBOARD_CMDS.windows }
  end
  if env_nonempty(context, "TERMUX_VERSION") then
    backends[#backends + 1] = READ_CLIPBOARD_CMDS.termux
  end
  if env_nonempty(context, "WAYLAND_DISPLAY") then
    backends[#backends + 1] = READ_CLIPBOARD_CMDS.wayland
  end
  if env_nonempty(context, "DISPLAY") then
    backends[#backends + 1] = READ_CLIPBOARD_CMDS.xclip
    backends[#backends + 1] = READ_CLIPBOARD_CMDS.xsel
  end
  -- Feature detection keeps macOS out of platform-condition branches:
  -- pbpaste succeeds there and simply fails on hosts where it is absent.
  backends[#backends + 1] = READ_CLIPBOARD_CMDS.macos
  return backends
end

local function default_read_runner(argv, context)
  if
    type(psi.time_ms) == "function"
    and context.deadline_ms ~= nil
    and psi.time_ms() >= context.deadline_ms
  then
    return { status = -1, output = "", truncated = false }
  end
  if
    type(psi.process_begin_argv) == "function"
    and type(psi.process_poll) == "function"
    and type(psi.process_finish) == "function"
    and type(psi.process_terminate) == "function"
    and type(psi.time_ms) == "function"
  then
    local handle = psi.process_begin_argv(argv)
    if handle == nil then
      return { status = -1, output = "", truncated = false }
    end
    local timeout_ms = tonumber(context.timeout_ms) or DEFAULT_READ_TIMEOUT_MS
    local deadline = context.deadline_ms or (psi.time_ms() + math.max(1, timeout_ms))
    while true do
      local remaining = deadline - psi.time_ms()
      if remaining <= 0 then
        pcall(psi.process_terminate, handle)
        pcall(psi.process_finish, handle)
        return { status = -1, output = "", truncated = false }
      end
      local ok, _, done = pcall(psi.process_poll, handle, math.min(50, remaining))
      if not ok then
        pcall(psi.process_terminate, handle)
        pcall(psi.process_finish, handle)
        return { status = -1, output = "", truncated = false }
      end
      if done then
        local finish_ok, result = pcall(psi.process_finish, handle)
        if finish_ok and type(result) == "table" then
          return result
        end
        return { status = -1, output = "", truncated = false }
      end
    end
  end
  if type(psi.process_run_argv) == "function" then
    return psi.process_run_argv(argv)
  end
  return { status = -1, output = "", truncated = false }
end

-- Shared bounded process runner for clipboard readers. Image backends use it
-- for type discovery and for helpers that write binary data to a temp file;
-- keeping this here makes image and text fallback obey the same timeout model.
function M._run_read_command(argv, context)
  context = type(context) == "table" and context or {}
  local runner = context.run_argv or default_read_runner
  if type(runner) ~= "function" then
    return { status = -1, output = "", truncated = false }
  end
  local ok, result = pcall(runner, argv, context)
  if not ok or type(result) ~= "table" then
    return { status = -1, output = "", truncated = false }
  end
  return result
end

local function run_read_backend(backend, context)
  local result = M._run_read_command(backend.argv, context)
  if tonumber(result.status) ~= 0 then
    return false
  end
  if result.truncated == true then
    return true, nil, "clipboard text too large"
  end
  local text = tostring(result.output or "")
  return true, text ~= "" and text or nil
end

local function enabled()
  return settings.get(CONFIG_ENABLED, DEFAULT_ENABLED) ~= false
end

local function target()
  local configured = settings.get(CONFIG_TARGET, DEFAULT_TARGET)
  if type(configured) == "string" then
    -- The target is interpolated raw into an OSC 52 sequence; strip
    -- anything that could terminate or escape the sequence.
    local sanitized = configured:gsub("[^%w]", "")
    if sanitized ~= "" then
      return sanitized
    end
  end
  return DEFAULT_TARGET
end

local function max_bytes()
  local configured = tonumber(settings.get(CONFIG_MAX_BYTES, DEFAULT_MAX_BYTES))
  if configured ~= nil and configured > 0 then
    return configured
  end
  return DEFAULT_MAX_BYTES
end

local function tmux_passthrough()
  return settings.get(CONFIG_TMUX_PASSTHROUGH, DEFAULT_TMUX_PASSTHROUGH) ~= false
end

M.base64_encode = base64.encode

local function osc52_sequence_from_encoded(encoded, env)
  env = type(env) == "table" and env or {}
  local sequence = OSC52_PREFIX .. target() .. ";" .. encoded .. BEL
  local tmux = env[ENV_TMUX]
  if tmux == nil then
    tmux = os.getenv(ENV_TMUX)
  end
  if tmux ~= nil and tmux ~= "" and tmux_passthrough() then
    return TMUX_DCS_PREFIX .. sequence .. TMUX_DCS_SUFFIX
  end
  return sequence
end

function M.osc52_sequence(text, env)
  return osc52_sequence_from_encoded(M.base64_encode(text), env)
end

function M.write_osc52(text, context)
  context = type(context) == "table" and context or {}
  text = tostring(text or "")
  if (not enabled() and not context.force) or text == "" then
    return false
  end
  local encoded = M.base64_encode(text)
  if not context.force and #encoded > max_bytes() then
    return false, "osc52 payload too large"
  end
  local sequence = osc52_sequence_from_encoded(encoded, context.env)
  if type(psi.tui_write) == "function" then
    local ok = pcall(psi.tui_write, sequence)
    if ok then
      return true, "osc52"
    end
  end
  psi.stdout_write(sequence)
  return true, "osc52"
end

function M.write_system(text)
  for _, backend in ipairs(CLIPBOARD_CMDS) do
    local handle = io.popen(backend.cmd .. " 2>/dev/null", "w")
    if handle then
      local ok_write = pcall(function()
        handle:write(text)
        handle:flush()
      end)
      local ok_close, _, rc = handle:close()
      if ok_write and ok_close and (rc == nil or rc == 0) then
        return true, backend.name
      end
    end
  end
  return false, "clipboard unavailable"
end

-- Read plain text from the system clipboard. The first backend that runs
-- successfully owns the result, including an empty clipboard; this prevents a
-- successful empty Wayland read from falling back to stale X11 clipboard data.
function M.read_system(context)
  context = type(context) == "table" and context or {}
  if type(psi.time_ms) == "function" and context.deadline_ms == nil then
    local timeout_ms = tonumber(context.timeout_ms) or DEFAULT_READ_TIMEOUT_MS
    context.deadline_ms = psi.time_ms() + math.max(1, timeout_ms)
  end
  for _, backend in ipairs(read_backends(context)) do
    local available, text, err = run_read_backend(backend, context)
    if available then
      return text, backend.name, err
    end
  end
  return nil, "clipboard unavailable"
end

function M.write(text, context)
  context = type(context) == "table" and context or {}
  text = tostring(text or "")
  if text == "" then
    return false, "empty clipboard payload"
  end
  local ok, backend = M.write_osc52(text, context)
  if ok then
    return true, backend
  end
  if context.allow_system == true then
    return M.write_system(text)
  end
  return false, backend
end

return M
