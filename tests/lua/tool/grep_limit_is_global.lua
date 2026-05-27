--[==[psi-test
expect = "1|true"
files = [
  { path = "grep-limit-a.txt", text = "needle a1\nneedle a2\n" },
  { path = "grep-limit-b.txt", text = "needle b1\nneedle b2\n" },
]
]==]
local r = require("psi.tools").dispatch("grep", {
  pattern = "needle",
  path = TMP,
  limit = 1,
})
local output = r.extras.output or ""
local matches = 0
for _ in output:gmatch("%.txt:") do
  matches = matches + 1
end
return tostring(matches) .. "|" .. tostring(r.extras.limit_reached)
