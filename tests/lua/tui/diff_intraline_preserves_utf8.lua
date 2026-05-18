--[==[psi-test
expect = "true|true"
]==]
local ansi = require("psi.ansi")
local diff = require("psi.tui_components.diff")
ansi.enabled = true
ansi.color_enabled = true
local out = diff.render_diff("@@ -1 +1 @@\n-é\n+ê")
return table.concat({
  tostring(out:find("é", 1, true) ~= nil),
  tostring(out:find("ê", 1, true) ~= nil),
}, "|")
