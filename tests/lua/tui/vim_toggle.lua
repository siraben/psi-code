--[[psi-test
expect = "-|insert|||Vim keybindings enabled|normal|||Vim keybindings disabled|insert|"
]]
local rt = require("psi.tui_runtime")
local function run(input, events)
  local s = rt._debug_edit_keys(input, #input, events)
  return table.concat({s.status_text or "-", s.editor_mode, s.input}, "|")
end
return table.concat({
  run("", {{key="escape"}}),
  run("/vim", {{key="enter"}, {key="escape"}}),
  run("/vim off", {{key="enter"}, {key="escape"}})
}, "||")
