--[==[psi-test
expect = "true|true|true"
env = { OS = "Windows_NT", TERM = "" }
]==]
local ansi = require("psi.ansi")
local platform = require("psi.platform")
ansi.enabled = true
ansi.color_enabled = true
ansi.autodetect()
return table.concat({
  tostring(platform.is_windows()),
  tostring(platform.windows_ansi_supported()),
  tostring(ansi.red("x"):sub(1, 2) == string.char(27) .. "["),
}, "|")
