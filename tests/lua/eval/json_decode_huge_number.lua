--[==[psi-test
expect = "number"
]==]
local text = '{"z":null,"a":[null,false],"sections":{"preamble":"base","tools":null}}'
local value = psi.json_decode(text, true)
assert(value.z == psi.json_null and value.a[1] == psi.json_null and value.a[2] == false)
assert(psi.json_encode(value) == text)
assert(psi.json_decode('{"z":null}').z == nil)
return type(psi.json_decode("1e309"))
