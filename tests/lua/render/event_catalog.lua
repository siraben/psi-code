--[==[psi-test
contains = ["before-turn", "tool-call", "tool-result", "after-turn"]
]==]
return table.concat(require("psi.render").events(), ",")
