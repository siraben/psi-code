--[==[psi-test
expect = "true|alpha\nbeta\ngamma|3|beta\ngamma|界\nOK|界"
]==]
local path = TMP .. "/powershell-outfile.txt"
local f = assert(io.open(path, "wb"))
f:write(
  "\255\254"
    .. "a\0l\0p\0h\0a\0\n\0"
    .. "b\0e\0t\0a\0\n\0"
    .. "g\0a\0m\0m\0a\0"
)
f:close()

local be_path = TMP .. "/utf16be.txt"
local be = assert(io.open(be_path, "wb"))
be:write("\254\255\117\76\0\10\0O\0K")
be:close()

local le_split_path = TMP .. "/utf16le-split.txt"
local le_split = assert(io.open(le_split_path, "wb"))
le_split:write("\255\254" .. "x\0\n\0" .. "\76\117")
le_split:close()

local tools = require("psi.tools")
local first = tools.dispatch("read", { path = path, offset = 1, limit = 10 })
local second = tools.dispatch("read", { path = path, offset = 2, limit = 10 })
local big_endian = tools.dispatch("read", { path = be_path, offset = 1, limit = 10 })
local le_aligned = tools.dispatch("read", { path = le_split_path, offset = 2, limit = 10 })
return table.concat({
  tostring(first.ok),
  first.extras.text or "",
  tostring(first.extras.total_lines),
  second.extras.text or "",
  big_endian.extras.text or "",
  le_aligned.extras.text or "",
}, "|")
