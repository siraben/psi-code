--[==[psi-test
expect = "true|true|TAIL"
]==]
local rt = require("psi.tui_runtime")
local text = rt._debug_limit_live_tool_progress_text(string.rep("a", 9000) .. "TAIL")
return table.concat({
  tostring(#text <= 8192),
  tostring(text:find("earlier output truncated", 1, true) ~= nil),
  text:sub(-4)
}, "|")
