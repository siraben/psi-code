-- Built-in OSC 52 clipboard writer for TUI yanks.

local clipboard = require("psi.clipboard")

local M = {}

local writer_id = nil

local function write_clipboard(text, clipboard_context)
  return clipboard.write_osc52(text, clipboard_context)
end

function M.enable(psi_state)
  if writer_id ~= nil then
    return true
  end
  local tui = (psi_state and psi_state.tui) or require("psi.tui_status")
  writer_id = tui.register_clipboard_writer(write_clipboard)
  return true
end

function M.disable(psi_state)
  if writer_id == nil then
    return true
  end
  local tui = (psi_state and psi_state.tui) or require("psi.tui_status")
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
M.write_clipboard = write_clipboard
M._debug_base64_encode = clipboard.base64_encode
M._debug_osc52_sequence = clipboard.osc52_sequence

return M
