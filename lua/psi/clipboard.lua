-- psi.clipboard: shared clipboard backends for slash commands and TUI.

local settings = require("psi.settings_manager")

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

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

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
  if type(configured) == "string" and configured ~= "" then
    return configured
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

local function byte_at(text, index)
  return text:byte(index, index) or 0
end

local function base64_char(index)
  return BASE64_ALPHABET:sub(index + 1, index + 1)
end

function M.base64_encode(text)
  text = tostring(text or "")
  local out = {}
  local out_index = 0
  for index = 1, #text, 3 do
    local first = byte_at(text, index)
    local second = byte_at(text, index + 1)
    local third = byte_at(text, index + 2)
    local triple = (first << 16) | (second << 8) | third
    local remaining = #text - index + 1

    out_index = out_index + 1
    out[out_index] = base64_char((triple >> 18) & 0x3f)
    out_index = out_index + 1
    out[out_index] = base64_char((triple >> 12) & 0x3f)
    out_index = out_index + 1
    out[out_index] = remaining >= 2 and base64_char((triple >> 6) & 0x3f) or "="
    out_index = out_index + 1
    out[out_index] = remaining >= 3 and base64_char(triple & 0x3f) or "="
  end
  return table.concat(out)
end

function M.osc52_sequence(text, env)
  env = type(env) == "table" and env or {}
  local sequence = OSC52_PREFIX .. target() .. ";" .. M.base64_encode(text) .. BEL
  local tmux = env[ENV_TMUX]
  if tmux == nil then
    tmux = os.getenv(ENV_TMUX)
  end
  if tmux ~= nil and tmux ~= "" and tmux_passthrough() then
    return TMUX_DCS_PREFIX .. sequence .. TMUX_DCS_SUFFIX
  end
  return sequence
end

function M.write_osc52(text, context)
  context = type(context) == "table" and context or {}
  text = tostring(text or "")
  if (not enabled() and not context.force) or text == "" then
    return false
  end
  if not context.force and #text > max_bytes() then
    return false, "osc52 payload too large"
  end
  psi.stdout_write(M.osc52_sequence(text, context.env))
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
  if context.prefer_osc52 then
    return M.write_osc52(text, context)
  end
  local ok, backend = M.write_system(text)
  if ok then
    return true, backend
  end
  return M.write_osc52(text, context)
end

return M
