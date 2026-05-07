--[==[psi-test
expect = "true"
]==]
local diff = require("psi.diff")
local cr = string.char(13)
local raw = "a\nb" .. cr .. "\nc"
local applied = assert(diff.apply_edits_to_text(raw, {
  { oldText = "a", newText = "x" },
}, "mixed.txt"))
return tostring(applied.output == ("x\nb" .. cr .. "\nc"))
