--[==[psi-test
contains = ["REPLACED", "tail"]
not_contains = "first"
]==]
local r = require("psi.render")
r.register_hook("before-turn", function() return "first\n" end)
r.register_hook("before-turn", function()
  return { replace = true, text = "REPLACED\n" }
end)
r.register_hook("before-turn", function() return "tail\n" end)
return r.handle_event("before-turn", {})
