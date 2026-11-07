--[==[psi-test
expect = "true|true|true"
]==]
local rt = require("psi.tui_runtime")
local calls = rt._debug_redraw_counts("x", { width = 4, height = 12 })
for _, height in ipairs({1, 4, 8}) do
  for _, width in ipairs({1, 8, 40}) do
    local frame = rt._debug_redraw_counts("first\nsecond\nthird", {width = width, height = height})
    assert(#frame.first_lines <= height, "frame must fit the physical terminal")
    assert(frame.first_col >= 1 and frame.first_col <= math.max(1, width - 1))
    for _, line in ipairs(frame.first_lines) do
      assert(require("psi.tui_text").visible_width(line) <= math.max(1, width - 1))
    end
  end
end

return table.concat({
  tostring(calls.first_frames > 0),
  tostring((calls.first_line_width or 0) <= 4),
  tostring((calls.first_col or 0) <= 4),
}, "|")
