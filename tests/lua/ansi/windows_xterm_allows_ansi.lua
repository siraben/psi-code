--[==[psi-test
expect = "true|true|true"
env = { OS = "Windows_NT", TERM = "xterm-256color" }
]==]
local ansi = require("psi.ansi")
local platform = require("psi.platform")
ansi.enabled = true
ansi.color_enabled = true
ansi.autodetect()
return table.concat({
  tostring(platform.windows_ansi_supported()),
  tostring(ansi.enabled),
  tostring(ansi.red("x"):sub(1, 2) == string.char(27) .. "["),
}, "|")
