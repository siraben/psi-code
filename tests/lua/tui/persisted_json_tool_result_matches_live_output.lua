--[==[psi-test
expect = "true|true|true|true|true"
]==]
local ansi = require("psi.ansi")
local text = require("psi.tui_text")
local rt = require("psi.tui_runtime")

ansi.enabled = true
ansi.color_enabled = true

local payload =
  [=[{"ok":true,"truncated":false,"status":0,"tool":"bash","command":"find . -maxdepth 1 -type f | wc -l","output":"17\nREADME.md\n","total_bytes":14}]=]
local out = rt._debug_persisted_tool_result_text("bash", payload, false)
local plain = text.strip_ansi(out)
return table.concat({
  tostring(plain:find("exit 0", 1, true) == nil),
  tostring(plain:find("17", 1, true) ~= nil),
  tostring(plain:find("README.md", 1, true) ~= nil),
  tostring(plain:find('"output"', 1, true) == nil),
  tostring(plain:find('{"ok":true', 1, true) == nil),
}, "|")
