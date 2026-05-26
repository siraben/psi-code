--[==[psi-test
expect = "ok"
]==]
local text = require("psi.tui_text")

local ESC = string.char(27)
local BEL = string.char(7)

local function assert_true(value, label)
  if not value then
    error(label, 0)
  end
end

local st_open = ESC .. "]8;;https://example.com" .. ESC .. "\\"
local st_close = ESC .. "]8;;" .. ESC .. "\\"
local st_lines = text.wrap_ansi(st_open .. "0123456789" .. st_close, 6)
assert_true(#st_lines == 2, "ST OSC 8 should wrap")
assert_true(st_lines[1]:sub(1, #st_open) == st_open, "first ST line should open link")
assert_true(st_lines[1]:sub(-#st_close) == st_close, "first ST line should close link")
assert_true(st_lines[2]:sub(1, #st_open) == st_open, "second ST line should reopen link")
assert_true(st_lines[2]:sub(-#st_close) == st_close, "second ST line should keep final close")

local bel_open = ESC .. "]8;;https://example.com" .. BEL
local bel_close = ESC .. "]8;;" .. BEL
local bel_lines = text.wrap_ansi(bel_open .. "0123456789" .. bel_close, 6)
assert_true(#bel_lines == 2, "BEL OSC 8 should wrap")
assert_true(bel_lines[1]:sub(1, #bel_open) == bel_open, "first BEL line should open link")
assert_true(bel_lines[1]:sub(-#bel_close) == bel_close, "first BEL line should close link")
assert_true(bel_lines[2]:sub(1, #bel_open) == bel_open, "second BEL line should reopen link")
assert_true(not bel_lines[2]:find(ESC .. "\\", 1, true), "BEL link should not reopen with ST")

local styled = text.wrap_ansi(ESC .. "[48;5;1m" .. ESC .. "[4mabcdef" .. ESC .. "[0m", 3)
assert_true(#styled == 2, "styled text should wrap")
assert_true(not styled[1]:find(ESC .. "[0m", 1, true), "intermediate line should not full-reset")
assert_true(styled[1]:sub(-#(ESC .. "[24m")) == ESC .. "[24m", "underline should turn off at wrap")
assert_true(styled[2]:find(ESC .. "[48;5;1m", 1, true) ~= nil, "background should reopen")
assert_true(styled[2]:find(ESC .. "[4m", 1, true) ~= nil, "underline should reopen")

local newline = text.wrap_ansi("alpha\nbeta", 80)
assert_true(#newline == 2, "literal newline should split lines")
assert_true(newline[1] == "alpha" and newline[2] == "beta", "literal newline contents")

return "ok"
