--[==[psi-test
expect = "false|false|x"
env = { OS = "Windows_NT", TERM = "", PSI_ANSI = "0" }
]==]
local ansi = require("psi.ansi")
local platform = require("psi.platform")
ansi.enabled = true
ansi.color_enabled = true
ansi.autodetect()
return table.concat({
  tostring(platform.windows_ansi_supported()),
  tostring(ansi.enabled),
  ansi.red("x"),
}, "|")
