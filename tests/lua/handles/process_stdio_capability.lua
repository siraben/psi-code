--[==[psi-test
expect = "true|function"
]==]
local info = psi.runtime_info()
return tostring(info.mcp) .. "|" .. type(psi.process_begin_stdio_argv)
