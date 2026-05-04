--[==[psi-test
expect = "argv test|0|false"
]==]
local r = psi.process_run_argv({"printf", "%s", "argv test"})
return r.output .. "|" .. tostring(r.status) .. "|" .. tostring(r.truncated)
