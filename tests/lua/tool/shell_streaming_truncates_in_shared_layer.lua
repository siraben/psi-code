--[==[psi-test
contains = ["true|2|three\nfour", "Showing lines 3-4 of 4"]
]==]
local shell = require("psi.tool_shell")
local r = shell.run_streaming("printf 'one\\ntwo\\nthree\\nfour'", nil, {
  max_lines = 2,
  max_bytes = 1000,
  mode = "tail",
  spill_to_disk = false,
  truncate_final = true,
  notice = "tail",
})
return tostring(r.truncated) .. "|"
  .. tostring(r.truncation_meta.output_lines) .. "|"
  .. r.output
