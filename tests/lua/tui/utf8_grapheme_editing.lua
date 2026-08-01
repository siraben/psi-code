--[==[psi-test
expect = "true|true|true|true|true|true"
]==]
local rt = require("psi.tui_runtime")

local function preserves_cluster(unit)
  local input = "A" .. unit .. "B"
  local after_unit = 1 + #unit
  local backspace = rt._debug_edit_keys(input, after_unit, { { key = "backspace" } }, false)
  local delete =
    rt._debug_edit_keys(input, after_unit, { { key = "left" }, { key = "delete" } }, false)
  local move = rt._debug_edit_keys(input, 1, { { key = "right" }, { key = "left" } }, false)
  return backspace.input == "AB"
    and backspace.cursor == 1
    and delete.input == "AB"
    and delete.cursor == 1
    and move.cursor == 1
end

require("psi.extensions.vim_keybindings").enable(psi)
local vim_append = rt._debug_edit_keys("éB", 0, {
  { key = "escape" },
  { key = "text", text = "a" },
  { key = "text", text = "!" },
})

return table.concat({
  tostring(preserves_cluster("é")),
  tostring(preserves_cluster("é")),
  tostring(preserves_cluster("👩‍💻")),
  tostring(preserves_cluster("🇺🇸")),
  tostring(preserves_cluster("界")),
  tostring(vim_append.input == "é!B" and vim_append.cursor == #"é!"),
}, "|")
