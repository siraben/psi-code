--[==[psi-test
expect = "false|true"
]==]
local path = TMP .. "/read-fifo"
psi.process_run_argv({"mkfifo", path})
local r = require("psi.tools").dispatch("read", { path = path })
return tostring(r.ok) .. "|" .. tostring((r.error or ""):find("Cannot read file:", 1, true) ~= nil)
