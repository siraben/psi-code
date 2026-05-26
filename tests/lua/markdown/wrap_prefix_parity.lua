--[==[psi-test
expect = "ok"
]==]
local Markdown = require("psi.tui_components.markdown")
local text = require("psi.tui_text")

local function assert_true(value, label)
  if not value then
    error(label, 0)
  end
end

local list = Markdown.new({ text = "- alpha beta gamma delta epsilon" })
local list_lines = list:render(20)
local list_plain = {}
for i, line in ipairs(list_lines) do
  list_plain[i] = text.strip_ansi(line):gsub("%s+$", "")
end
assert_true(#list_plain == 2, "list should wrap to two lines")
assert_true(list_plain[1] == "• alpha beta gamma", "list first line keeps marker")
assert_true(list_plain[2] == "  delta epsilon", "list continuation aligns after marker")

local ordered = Markdown.new({ text = "10. alpha beta gamma delta epsilon" })
local ordered_lines = ordered:render(21)
local ordered_plain = {}
for i, line in ipairs(ordered_lines) do
  ordered_plain[i] = text.strip_ansi(line):gsub("%s+$", "")
end
assert_true(#ordered_plain == 2, "ordered list should wrap to two lines")
assert_true(ordered_plain[1] == "10. alpha beta gamma", "ordered first line keeps marker")
assert_true(ordered_plain[2] == "    delta epsilon", "ordered continuation aligns after marker")

local quote = Markdown.new({ text = "> alpha beta gamma delta epsilon zeta" })
local quote_lines = quote:render(20)
local quote_plain = {}
for i, line in ipairs(quote_lines) do
  quote_plain[i] = text.strip_ansi(line):gsub("%s+$", "")
end
assert_true(#quote_plain >= 2, "blockquote should wrap")
for _, line in ipairs(quote_plain) do
  assert_true(line:sub(1, #"│ ") == "│ ", "blockquote continuation should keep border")
end

local prefixed = Markdown.new({
  text = "- alpha beta gamma delta epsilon",
  prefix_first = "A ",
  prefix_rest = "B ",
})
local prefixed_lines = prefixed:render(22)
local prefixed_plain = {}
for i, line in ipairs(prefixed_lines) do
  prefixed_plain[i] = text.strip_ansi(line):gsub("%s+$", "")
end
assert_true(prefixed_plain[1] == "A • alpha beta gamma", "outer first prefix should compose with list marker")
assert_true(prefixed_plain[2] == "B   delta epsilon", "outer rest prefix should compose with continuation")

return "ok"
