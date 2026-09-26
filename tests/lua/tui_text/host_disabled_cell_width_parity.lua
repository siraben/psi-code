--[==[psi-test
expect = "ok"
]==]
local native = require("psi.tui_text")
local host = {
  visible_width = psi.tui_text_visible_width,
  byte_index_for_width = psi.tui_text_byte_index_for_width,
  wrap_ansi = psi.tui_text_wrap_ansi,
  clip_ansi = native.clip_ansi,
}

psi.tui_text_visible_width = nil
psi.tui_text_byte_index_for_width = nil
psi.tui_text_wrap_ansi = nil
psi.cell_width = nil
package.loaded["psi.tui_text"] = nil

local text = require("psi.tui_text")
local ESC = string.char(27)

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    error(label .. ": expected [" .. tostring(expected) .. "] got [" .. tostring(actual) .. "]", 0)
  end
end

local corpus = {
  "A",
  "界",
  "é",
  "Б҄",
  "שׁ",
  "بّ",
  "بٟ",
  "ܒܰ",
  "ހަ",
  "😀",
  "👍🏽",
  "👩‍💻",
  "🇺🇸",
  "〿",
}

for _, left in ipairs(corpus) do
  for _, right in ipairs(corpus) do
    local value = left .. right
    assert_equal(text.visible_width(value), host.visible_width(value), "visible width")
    local width = host.visible_width(value)
    for column = 0, width + 1 do
      assert_equal(
        text.byte_index_for_width(value, column),
        host.byte_index_for_width(value, column),
        "byte boundary"
      )
      assert_equal(text.clip_ansi(value, column), host.clip_ansi(value, column), "clipped value")
    end
    for columns = 1, 4 do
      assert_equal(
        table.concat(text.wrap_ansi(value, columns), "|"),
        table.concat(host.wrap_ansi(value, columns), "|"),
        "wrapped value"
      )
    end
  end
end

local arabic = "AبّB"
local host_lines = host.wrap_ansi(arabic, 2)
local fallback_lines = text.wrap_ansi(arabic, 2)
assert_equal(#fallback_lines, #host_lines, "Arabic line count")
for i = 1, #host_lines do
  assert_equal(fallback_lines[i], host_lines[i], "Arabic wrapped line")
end
assert_equal(fallback_lines[1], "Aبّ", "combining mark remains with base")

local styled = ESC .. "[4m" .. arabic .. ESC .. "[0m"
host_lines = host.wrap_ansi(styled, 2)
fallback_lines = text.wrap_ansi(styled, 2)
assert_equal(#fallback_lines, #host_lines, "styled line count")
for i = 1, #host_lines do
  assert_equal(fallback_lines[i], host_lines[i], "styled wrapped line")
end
for column = 0, 3 do
  assert_equal(
    text.clip_ansi(styled, column),
    host.clip_ansi(styled, column),
    "styled clipped value"
  )
end

local narrow = "A〿B"
host_lines = host.wrap_ansi(narrow, 2)
fallback_lines = text.wrap_ansi(narrow, 2)
assert_equal(table.concat(fallback_lines, "|"), table.concat(host_lines, "|"), "U+303F wrapping")
assert_equal(fallback_lines[1], "A〿", "U+303F remains narrow")

return "ok"
