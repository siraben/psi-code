-- psi.clipboard: shared clipboard backends for slash commands and TUI.

local settings = require("psi.settings_manager")
local base64 = require("psi.base64")

local M = {}

local CONFIG_ENABLED = "extensions.osc52_clipboard.enabled"
local CONFIG_TARGET = "extensions.osc52_clipboard.target"
local CONFIG_TMUX_PASSTHROUGH = "extensions.osc52_clipboard.tmux_passthrough"
local CONFIG_MAX_BYTES = "extensions.osc52_clipboard.max_bytes"

local DEFAULT_ENABLED = true
local DEFAULT_TARGET = "c"
local DEFAULT_TMUX_PASSTHROUGH = true
local DEFAULT_MAX_BYTES = 100000

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
  psi.stdout_write(osc52_sequence_from_encoded(encoded, context.env))
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
