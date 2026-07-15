--[==[psi-test
expect = "true"
]==]
local c = require("psi.slash_commands")
local r = c.input_completions("/re", 3, 24, false)
local found = false
for _, it in ipairs(r.items) do
  if it.insert == "/resume" then
    found = true
  end
end
return tostring(found and r.start == 1)
