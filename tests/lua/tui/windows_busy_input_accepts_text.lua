--[==[psi-test
expect = "draftx|6"
env = { OS = "Windows_NT", TERM = "" }
]==]
local rt = require("psi.tui_runtime")
local state = rt._debug_edit_keys("draft", 5, {
  { key = "text", text = "x" },
}, false, { busy = true, busy_kind = "agent" })
return state.input .. "|" .. tostring(state.cursor)
