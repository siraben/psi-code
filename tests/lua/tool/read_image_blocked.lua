--[==[psi-test
expect = "true|false|Image reading is disabled.|nil|true"
cwd = "read-image-blocked"
files = [
  { path = ".psi/settings.json", json = { images = { block_images = true } } },
]
]==]
local path = TMP .. "/tiny.png"
local png = string.char(0x89)
  .. "PNG\r\n"
  .. string.char(0x1a)
  .. "\n"
  .. string.char(0, 0, 0, 13)
  .. "IHDR"
assert(psi.file_write(path, png))
local r = require("psi.tools").dispatch("read", { path = path })
local content = r:get("content")
return table.concat({
  tostring(r.ok),
  tostring(r:get("image")),
  tostring(r:get("image_omitted")),
  tostring(content[2]),
  tostring((r:get("text") or ""):find("Image reading is disabled.", 1, true) ~= nil),
}, "|")
