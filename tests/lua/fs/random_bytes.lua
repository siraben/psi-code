--[==[psi-test
expect = "string|32"
]==]
local bytes = assert(psi.random_bytes(32))
return type(bytes) .. "|" .. tostring(#bytes)
