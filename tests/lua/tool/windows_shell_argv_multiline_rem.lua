--[==[psi-test
expect = "cmd.exe|/d|/c|echo after"
env = { OS = "Windows_NT", TERM = "" }
]==]
local platform = require("psi.platform")
return table.concat(platform.shell_argv("REM comment\necho after"), "|")
