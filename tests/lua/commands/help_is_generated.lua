--[[psi-test
contains = [
  "built-ins:",
  "/hotkeys",
  "/rainbow",
  "extensions:",
  "/greet <name>",
  "Say hello",
  "/btw <question>",
]
]]
local c = require("psi.slash_commands")
c.register("greet", {
  description = "Say hello",
  argument_hint = "<name>",
  handler = function() return nil end,
})
return c.help_text()
