--[==[psi-test
expect = "60000|60000"
]==]
local r = require("psi.tools").dispatch("bash", {
  command = "yes A | head -c 60000"
})
local body = psi.read_file(r.extras.temp_file_path or "") or ""
return tostring(r.extras.total_bytes) .. "|" .. tostring(#body)
