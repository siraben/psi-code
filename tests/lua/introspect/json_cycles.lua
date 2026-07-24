--[==[psi-test
expect = "false|false|true|false"
]==]
-- Cyclic or excessively nested tables must raise a Lua error instead
-- of exhausting the C stack.
local cyclic_obj = {}
cyclic_obj.self = cyclic_obj
local cyclic_arr = {}
cyclic_arr[1] = cyclic_arr
local deep = {}
local cur = deep
for i = 1, 500 do
  cur.child = { n = i }
  cur = cur.child
end
local too_deep = {}
cur = too_deep
for i = 1, 2000 do
  cur.c = {}
  cur = cur.c
end
return tostring(pcall(psi.json_encode, cyclic_obj)) .. "|"
  .. tostring(pcall(psi.json_encode, cyclic_arr)) .. "|"
  .. tostring(type(psi.json_encode(deep)) == "string") .. "|"
  .. tostring(pcall(psi.json_encode, too_deep))
