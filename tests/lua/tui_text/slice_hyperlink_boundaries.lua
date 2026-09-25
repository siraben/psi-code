--[==[psi-test
expect = "ok"
]==]
local text = require("psi.tui_text")
local app = require("psi.tui_app")
local esc = string.char(27)
local bel = string.char(7)
local open = esc .. "]8;;https://example.com" .. bel
local close = esc .. "]8;;" .. bel
local red = esc .. "[31m"
local reset = esc .. "[0m"
local linked = open .. "abcdef" .. close

assert(text.slice_by_columns(linked, 0, 2, true) == open .. "ab" .. close)
assert(text.slice_by_columns(linked, 2, 2, true) == open .. "cd" .. close)
assert(text.slice_by_columns(linked, 4, 2, true) == open .. "ef" .. close)
assert(text.clip_ansi(red .. linked .. reset, 3) == red .. open .. "abc" .. close .. reset)

local composite = app.composite_line(linked, "XY", 2, 2, 6)
assert(composite == open .. "ab" .. close .. "XY" .. open .. "ef" .. close)
return "ok"
