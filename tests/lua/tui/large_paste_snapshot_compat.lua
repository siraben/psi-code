--[==[psi-test
expect = "true|true|true"
env = { HOME = "{TMP}/keybindings-home" }
files = [
  { path = "keybindings-home/.config/psi/keybindings.json", json = { "tui.queue.previous" = "ctrl-p" } },
]
]==]
local agent = require("psi.agent_session")
local kb = require("psi.keybindings")
local rt = require("psi.tui_runtime")
local payload = string.rep("x", 1001)
local function events(tail)
  local out = {
    { key = "paste-start" },
    { key = "text", text = payload },
    { key = "paste-end" },
  }
  for _, event in ipairs(tail) do
    out[#out + 1] = event
  end
  return out
end
local undo_ok = true
if #kb.keys("tui.editor.undo") > 0 then
  local undo =
    rt._debug_edit_keys("", 0, events({ { key = "backspace" }, { key = "ctrl--" } }), false)
  undo_ok = undo.expanded_input == payload and undo.paste_count == 1
end
agent.clear_queues()
agent.queue_follow_up("queued")
local restored = rt._debug_edit_keys("", 0, events({ { key = "alt-up" } }), false, { busy = true })
local restore_ok = restored.expanded_input == "queued\n\n" .. payload
agent.clear_queues()
agent.queue_follow_up("queued")
-- Queue draft support arrives in the separate queue restoration port.
local probe = rt._debug_consume_queued_preview("preview", "preview", { queue_nav_draft = "draft" })
local queue_ok = true
if probe.input == "draft" then
  local draft = rt._debug_edit_keys(
    "",
    0,
    events({ { key = "ctrl-p" }, { key = "escape" } }),
    false,
    { busy = true }
  )
  queue_ok = draft.expanded_input == "queued\n\n" .. payload
end
agent.clear_queues()
return tostring(undo_ok) .. "|" .. tostring(restore_ok) .. "|" .. tostring(queue_ok)
