--[==[psi-test
expect = "|plain text\n||next line|1|10000"
]==]
local markdown = require("psi.markdown")

local stream = markdown.new_stream()
local first = stream:feed("plain ")
local second = stream:feed("text\nnext ")
local third = stream:feed("line")
local final = stream:flush()

local tokens = markdown.parse_inline(string.rep("a", 10000))
return table.concat(
  { first, second, third, final, tostring(#tokens), tostring(#tokens[1].text) },
  "|"
)
