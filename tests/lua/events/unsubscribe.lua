--[==[psi-test
expect = "2,3,1"
]==]
local calls = 0
local function handler()
  calls = calls + 1
end
local unsubscribe = psi.events.on("unsubscribe-test", handler)
psi.events.on("unsubscribe-test", handler)
psi.events.emit("unsubscribe-test", {})
local first = calls
unsubscribe()
psi.events.emit("unsubscribe-test", {})
return table.concat({ first, calls, #psi.events.handlers("unsubscribe-test") }, ",")
