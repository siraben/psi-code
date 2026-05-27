--[==[psi-test
expect = "cmd.exe|/d|/c|echo hello"
env = { OS = "Windows_NT", TERM = "" }
]==]
local platform = require("psi.platform")
return table.concat(platform.shell_argv("echo hello"), "|")
