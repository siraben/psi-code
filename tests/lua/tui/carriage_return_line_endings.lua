--[==[psi-test
expect = "one|two|three|four|one|two|three|four|one|two|three|four|one|two|three|four"
]==]
local source = "one\r\ntwo\rthree\nfour"

local host_wrapped = psi.tui_text_wrap_ansi(source, 80)
local host_preserved = psi.tui_text_wrap_ansi(source, 80, { preserve_whitespace = true })

local host_wrap = psi.tui_text_wrap_ansi
psi.tui_text_wrap_ansi = nil
package.loaded["psi.tui_text"] = nil
local fallback = require("psi.tui_text")
local lua_wrapped = fallback.wrap_ansi(source, 80)
local lua_preserved = fallback.wrap_ansi(source, 80, { preserve_whitespace = true })
psi.tui_text_wrap_ansi = host_wrap

return table.concat({
  table.concat(host_wrapped, "|"),
  table.concat(host_preserved, "|"),
  table.concat(lua_wrapped, "|"),
  table.concat(lua_preserved, "|"),
}, "|")
