--[==[psi-test
expect = "ok"
]==]
psi.tui_text_wrap_ansi = nil
package.loaded["psi.tui_text"] = nil

local text = require("psi.tui_text")
local ESC = string.char(27)
local BEL = string.char(7)

local function assert_true(value, label)
  if not value then
    error(label, 0)
  end
end

local open = ESC .. "]8;;https://example.com" .. BEL
local close = ESC .. "]8;;" .. BEL
local lines = text.wrap_ansi(open .. "0123456789" .. close, 6)
assert_true(#lines == 2, "fallback OSC 8 should wrap")
assert_true(lines[1]:sub(-#close) == close, "fallback should close OSC 8 before wrap")
assert_true(lines[2]:sub(1, #open) == open, "fallback should reopen OSC 8")

local styled = text.wrap_ansi(ESC .. "[48;5;1m" .. ESC .. "[4mabcdef" .. ESC .. "[0m", 3)
assert_true(not styled[1]:find(ESC .. "[0m", 1, true), "fallback should avoid full reset")
assert_true(styled[1]:sub(-#(ESC .. "[24m")) == ESC .. "[24m", "fallback should stop underline")

local newline = text.wrap_ansi("alpha\nbeta", 80)
assert_true(#newline == 2 and newline[1] == "alpha" and newline[2] == "beta", "fallback newlines")

return "ok"
