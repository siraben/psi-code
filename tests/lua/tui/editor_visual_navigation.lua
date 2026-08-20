--[==[psi-test
expect = "23|100|15|10|11|6|7|7|1|6|3|8"
]==]
local rt = require("psi.tui_runtime")

local wrapped = string.rep("a", 100)
local up = rt._debug_edit_keys(wrapped, #wrapped, { { key = "up" } }, false, { width = 80 })
local down = rt._debug_edit_keys(wrapped, up.cursor, { { key = "down" } }, false, { width = 80 })

local sticky = "2222222222x222\n\n1111111111_111111111111"
local short = rt._debug_edit_keys(sticky, 26, { { key = "up" } }, false, { width = 80 })
local restored = rt._debug_edit_keys(
  sticky,
  26,
  { { key = "up" }, { key = "up" } },
  false,
  { width = 80 }
)

local wide = "界界界\nx\n界界界"
local wide_short = rt._debug_edit_keys(wide, 18, { { key = "up" } }, false, { width = 80 })
local wide_restored = rt._debug_edit_keys(
  wide,
  18,
  { { key = "up" }, { key = "up" } },
  false,
  { width = 80 }
)

local gap = "hello   world end"
local gap_roundtrip = rt._debug_edit_keys(
  gap,
  7,
  { { key = "down" }, { key = "up" } },
  false,
  { width = 10 }
)

local snapped = "a\n界\nb"
local snapped_down = rt._debug_edit_keys(
  snapped,
  1,
  { { key = "down" }, { key = "down" } },
  false,
  { width = 80 }
)
local snapped_roundtrip = rt._debug_edit_keys(
  snapped,
  1,
  { { key = "down" }, { key = "down" }, { key = "up" }, { key = "up" } },
  false,
  { width = 80 }
)

local hidden = "aaaa    bbbb    cccc"
local hidden_roundtrip = rt._debug_edit_keys(
  hidden,
  6,
  { { key = "up" }, { key = "down" } },
  false,
  { width = 6 }
)

local narrow_wide = rt._debug_edit_keys(
  "界 x",
  3,
  { { key = "down" }, { key = "up" } },
  false,
  { width = 3 }
)
local narrow_emoji = rt._debug_edit_keys(
  "👍🏽 x",
  8,
  { { key = "down" }, { key = "up" } },
  false,
  { width = 4 }
)

return table.concat({
  tostring(up.cursor),
  tostring(down.cursor),
  tostring(short.cursor),
  tostring(restored.cursor),
  tostring(wide_short.cursor),
  tostring(wide_restored.cursor),
  tostring(gap_roundtrip.cursor),
  tostring(snapped_down.cursor),
  tostring(snapped_roundtrip.cursor),
  tostring(hidden_roundtrip.cursor),
  tostring(narrow_wide.cursor),
  tostring(narrow_emoji.cursor),
}, "|")
