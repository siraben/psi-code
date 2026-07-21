--[==[psi-test
expect = "true|[]|[]"
]==]
local prelude = require("psi.prelude")

local first = prelude.as_array({})
local second = prelude.as_array({})
return table.concat({
  tostring(rawequal(getmetatable(first), getmetatable(second))),
  psi.json_encode(first),
  psi.json_encode(second),
}, "|")
