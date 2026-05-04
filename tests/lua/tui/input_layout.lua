--[==[psi-test
expect = '18|" › "|"   "'
]==]
local prelude = require("psi.prelude")
local raw = require("psi.tui_layout").input_layout(
  psi.json_encode({width = 80, height = 24}))
local layout = prelude.safe_json_decode(raw, {})
return string.format("%d|%q|%q",
  layout.max_rows or -1,
  layout.prefix_first or "",
  layout.prefix_rest or "")
