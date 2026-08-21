--[==[psi-test
expect = "ok"
]==]
local host_wrap_ansi = psi.tui_text_wrap_ansi
psi.tui_text_wrap_ansi = nil
package.loaded["psi.tui_text"] = nil

local text = require("psi.tui_text")
local ESC = string.char(27)
local BEL = string.char(7)

local function assert_lines_equal(actual, expected, label)
  if #actual ~= #expected then
    error(label .. " line count", 0)
  end
  for i = 1, #expected do
    if actual[i] ~= expected[i] then
      error(label .. " line " .. tostring(i), 0)
    end
  end
end

local cases = {
  {
    open = ESC .. "]8;;https://example.com" .. BEL,
    close = ESC .. "]8;;" .. BEL,
  },
  {
    open = ESC .. "]8;;https://example.com" .. ESC .. "\\",
    close = ESC .. "]8;;" .. ESC .. "\\",
  },
}

for _, case in ipairs(cases) do
  local value = case.open .. "A界é👩‍💻B" .. case.close
  local expected = host_wrap_ansi(value, 3, { preserve_whitespace = true })
  local actual = text.wrap_ansi(value, 3, { preserve_whitespace = true })
  assert_lines_equal(actual, expected, "OSC 8 preserve-whitespace parity")
  for i = 1, #actual - 1 do
    if actual[i]:sub(-#case.close) ~= case.close then
      error("wrapped line did not close hyperlink", 0)
    end
    if actual[i + 1]:sub(1, #case.open) ~= case.open then
      error("continuation did not reopen hyperlink", 0)
    end
  end
end

return "ok"
