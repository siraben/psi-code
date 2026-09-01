--[==[psi-test
expect = "row A|row B|row C|0|true|false"
]==]
local tui = require("psi.tui_status")
local id_a = tui.register_footer_line(function(arg)
  return "row A"
end)
tui.register_footer_line(function()
  return "row B\nrow C"
end)
local rows = tui.footer_lines({ model = "m", busy = false, scroll = 0 })
local removed = tui.unregister_footer_line(id_a)
tui.clear_footer_line_hooks()
local out = {}
for _, row in ipairs(rows) do
  out[#out + 1] = row
end
out[#out + 1] = tostring(#tui.footer_lines({}))
out[#out + 1] = tostring(removed)
out[#out + 1] = tostring(tui.has_footer_line_hooks())
return table.concat(out, "|")
