--[[psi-test
expect = "8"
]]
local prelude = require("psi.prelude")
local layout_mod = require("psi.tui_layout")
layout_mod.set_prompt_max_rows(8)
local raw = layout_mod.input_layout(
  psi.json_encode({width = 80, height = 24}))
layout_mod.set_prompt_max_rows(nil)
local layout = prelude.safe_json_decode(raw, {})
return tostring(layout.max_rows or -1)
