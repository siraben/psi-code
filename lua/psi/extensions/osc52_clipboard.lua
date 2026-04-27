-- Built-in OSC 52 clipboard writer for TUI yanks.

local settings = require("psi.settings")

local M = {}

local CONFIG_ENABLED = "extensions.osc52_clipboard.enabled"
local CONFIG_TARGET = "extensions.osc52_clipboard.target"
local CONFIG_TMUX_PASSTHROUGH = "extensions.osc52_clipboard.tmux_passthrough"

local DEFAULT_ENABLED = true
local DEFAULT_TARGET = "c"
local DEFAULT_TMUX_PASSTHROUGH = true

local ENV_TMUX = "TMUX"

local ASCII_ESCAPE = 27
local ASCII_BEL = 7
local ESC = string.char(ASCII_ESCAPE)
local BEL = string.char(ASCII_BEL)
local ST = ESC .. "\\"
local OSC52_PREFIX = ESC .. "]52;"
local OSC52_SEPARATOR = ";"
local TMUX_DCS_PREFIX = ESC .. "Ptmux;" .. ESC
local TMUX_DCS_SUFFIX = ST

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_PAD = "="
local BYTE_BITS = 8
local BASE64_BITS = 6
local BASE64_MASK = 0x3f
local BASE64_INPUT_BYTES = 3
local BASE64_INDEX_OFFSET = 1
local BASE64_SECOND_BYTE_MINIMUM = 2
local BASE64_THIRD_BYTE_MINIMUM = 3

local writer_id = nil

local function is_enabled()
  return settings.get(CONFIG_ENABLED, DEFAULT_ENABLED) ~= false
end

local function target()
  local configured = settings.get(CONFIG_TARGET, DEFAULT_TARGET)
  if type(configured) == "string" and configured ~= "" then
    return configured
  end
  return DEFAULT_TARGET
end

local function tmux_passthrough_enabled()
  return settings.get(CONFIG_TMUX_PASSTHROUGH, DEFAULT_TMUX_PASSTHROUGH) ~= false
end

local function byte_at(text, index)
  return text:byte(index, index) or 0
end

local function base64_encode(text)
  text = tostring(text or "")
  local out = {}
  local out_index = 0
  for index = 1, #text, BASE64_INPUT_BYTES do
    local first = byte_at(text, index)
    local second = byte_at(text, index + 1)
    local third = byte_at(text, index + 2)
    local triple = (first << (BYTE_BITS * 2)) | (second << BYTE_BITS) | third
    local remaining = #text - index + 1
    local first_index = ((triple >> (BASE64_BITS * 3)) & BASE64_MASK) + BASE64_INDEX_OFFSET
    local second_index = ((triple >> (BASE64_BITS * 2)) & BASE64_MASK) + BASE64_INDEX_OFFSET
    local third_index = ((triple >> BASE64_BITS) & BASE64_MASK) + BASE64_INDEX_OFFSET
    local fourth_index = (triple & BASE64_MASK) + BASE64_INDEX_OFFSET

    out_index = out_index + 1
    out[out_index] = BASE64_ALPHABET:sub(first_index, first_index)
    out_index = out_index + 1
    out[out_index] = BASE64_ALPHABET:sub(second_index, second_index)
    out_index = out_index + 1
    out[out_index] = remaining >= BASE64_SECOND_BYTE_MINIMUM
        and BASE64_ALPHABET:sub(third_index, third_index)
      or BASE64_PAD
    out_index = out_index + 1
    out[out_index] = remaining >= BASE64_THIRD_BYTE_MINIMUM
        and BASE64_ALPHABET:sub(fourth_index, fourth_index)
      or BASE64_PAD
  end
  return table.concat(out)
end

local function osc52_sequence(text, env)
  env = type(env) == "table" and env or {}
  local encoded = base64_encode(text)
  local sequence = OSC52_PREFIX .. target() .. OSC52_SEPARATOR .. encoded .. BEL
  local tmux = env[ENV_TMUX]
  if tmux == nil then
    tmux = os.getenv(ENV_TMUX)
  end
  if tmux ~= nil and tmux ~= "" and tmux_passthrough_enabled() then
    return TMUX_DCS_PREFIX .. sequence .. TMUX_DCS_SUFFIX
  end
  return sequence
end

local function write_clipboard(text, clipboard_context)
  clipboard_context = type(clipboard_context) == "table" and clipboard_context or {}
  if (not is_enabled() and not clipboard_context.force) or text == nil or text == "" then
    return false
  end
  psi.stdout_write(osc52_sequence(text))
  return true
end

function M.enable(psi_state)
  if writer_id ~= nil then
    return true
  end
  local tui = (psi_state and psi_state.tui) or require("psi.tui")
  writer_id = tui.register_clipboard_writer(write_clipboard)
  return true
end

function M.disable(psi_state)
  if writer_id == nil then
    return true
  end
  local tui = (psi_state and psi_state.tui) or require("psi.tui")
  if tui.unregister_clipboard_writer then
    tui.unregister_clipboard_writer(writer_id)
  end
  writer_id = nil
  return true
end

function M.register(psi_state)
  return M.enable(psi_state)
end

M.install = M.enable
M._debug_base64_encode = base64_encode
M._debug_osc52_sequence = osc52_sequence

return M
