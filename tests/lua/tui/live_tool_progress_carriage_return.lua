--[==[psi-test
expect = "true|true|true|true|Downloading 3%"
]==]
local rt = require("psi.tui_runtime")

local text = rt._debug_limit_live_tool_progress_text("Downloading 1%\rDownloading 2%\rDownloading 3%")
return table.concat({
  tostring(text:find("\r", 1, true) == nil),
  tostring(text:find("\n", 1, true) == nil),
  tostring(text:find("Downloading 1%", 1, true) == nil),
  tostring(text:find("Downloading 3%", 1, true) ~= nil),
  text,
}, "|")
