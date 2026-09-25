--[==[psi-test
expect = "1,1,0"
]==]
local calls = 0
local unsubscribe = psi.events.on("unsubscribe-test", function()
  calls = calls + 1
end)
psi.events.emit("unsubscribe-test", {})
local first = calls
unsubscribe()
psi.events.emit("unsubscribe-test", {})
return table.concat({ first, calls, #psi.events.handlers("unsubscribe-test") }, ",")
