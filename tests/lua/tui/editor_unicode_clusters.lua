--[==[psi-test
expect = "2|4|0|true|2|8|0|true|2|11|0|true|2|10|0|true|2|12|0|true"
]==]
local rt = require("psi.tui_runtime")
local text = require("psi.tui_text")

local regional = "🇨"
local regional_right = rt._debug_edit_keys(regional, 0, { { key = "right" } }, false)
local regional_delete = rt._debug_edit_keys(regional, #regional, { { key = "backspace" } }, false)

local toned = "👍🏽"
local toned_right = rt._debug_edit_keys(toned, 0, { { key = "right" } }, false)
local toned_delete = rt._debug_edit_keys(toned, #toned, { { key = "backspace" } }, false)

local function cluster_result(value)
  local right = rt._debug_edit_keys(value, 0, { { key = "right" } }, false)
  local deleted = rt._debug_edit_keys(value, #value, { { key = "backspace" } }, false)
  return {
    tostring(text.visible_width(value)),
    tostring(right.cursor),
    tostring(deleted.cursor),
    tostring(deleted.input == ""),
  }
end

local flag_vs = cluster_result("🇨🇦️")
local flag_combining = cluster_result("🇨🇦́")
local flag_toned = cluster_result("🇨🇦🏽")

return table.concat({
  tostring(text.visible_width(regional)),
  tostring(regional_right.cursor),
  tostring(regional_delete.cursor),
  tostring(regional_delete.input == ""),
  tostring(text.visible_width(toned)),
  tostring(toned_right.cursor),
  tostring(toned_delete.cursor),
  tostring(toned_delete.input == ""),
  flag_vs[1],
  flag_vs[2],
  flag_vs[3],
  flag_vs[4],
  flag_combining[1],
  flag_combining[2],
  flag_combining[3],
  flag_combining[4],
  flag_toned[1],
  flag_toned[2],
  flag_toned[3],
  flag_toned[4],
}, "|")
