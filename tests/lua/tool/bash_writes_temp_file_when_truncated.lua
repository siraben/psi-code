--[==[psi-test
contains = "1|true"
]==]
local r = require("psi.tools").dispatch("bash", {
  command = "yes spillover | head -c 200000"
})
local tp = r.extras.temp_file_path
if not tp then return "no-path" end
local body = psi.read_file(tp)
return tostring(tp:find("^/")) .. "|" .. tostring(body and #body >= 200000)
