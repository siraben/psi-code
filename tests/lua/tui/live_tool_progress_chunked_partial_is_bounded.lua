--[==[psi-test
expect = "1000|true|TAIL"
]==]
local progress = require("psi.tui_runtime")._live_progress

local entry = {}
for _ = 1, 100 do
  progress.update(entry, string.rep("a", 100), false)
end
progress.update(entry, "TAIL", false)

local displayed = progress.display(entry)
return table.concat({
  tostring(#entry.progress_partial),
  tostring(displayed:sub(-4) == "TAIL"),
  displayed:sub(-4),
}, "|")
