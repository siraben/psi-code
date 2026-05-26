--[==[psi-test
expect = "true|true|true"
]==]
local path = TMP .. "/medium.png"
local png = string.char(0x89)
  .. "PNG\r\n"
  .. string.char(0x1a)
  .. "\n"
  .. string.char(0, 0, 0, 13)
  .. "IHDR"
assert(psi.file_write(path, png .. string.rep("x", 262144)))
local r = require("psi.tools").dispatch("read", { path = path })
local content = r:get("content")
return table.concat({
  tostring(r.ok),
  tostring(content[2] ~= nil),
  tostring((content[2] and #content[2].data or 0) > 262144),
}, "|")
