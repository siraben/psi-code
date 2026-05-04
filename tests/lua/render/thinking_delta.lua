--[==[psi-test
# Original split-and-check on stdout '|'-separated parts. Refactored to do all
# checks in Lua and return a single boolean tuple.
expect = "true|true|true|true"
]==]
local r = require("psi.render")
local a = r.handle_event("thinking-delta", { text = "first " })
local b = r.handle_event("thinking-delta", { text = "second" })
r.handle_event("after-turn", {})
local c = r.handle_event("thinking-delta", { text = "turn2" })
local function strip(s)
  return (s:gsub("\27%[[%d;]*m", ""))
end
local sa, sb, sc = strip(a), strip(b), strip(c)
return tostring(sa:find("thinking: first", 1, true) ~= nil) .. "|"
  .. tostring(sb:find("thinking:", 1, true) == nil) .. "|"
  .. tostring(sb:find("second", 1, true) ~= nil) .. "|"
  .. tostring(sc:find("thinking: turn2", 1, true) ~= nil)
