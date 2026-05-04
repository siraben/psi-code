--[==[psi-test
contains = "\u001b[38;5;123mx\u001b[0m"
]==]
local ansi = require("psi.ansi")
ansi.enabled = true
ansi.color_enabled = true
ansi.set_code_map({["38;5;242"] = "38;5;123"})
return ansi.gray("x")
