--[==[psi-test
cwd = "proj"
files = [
  { path = "src/main.c", text = "" },
  { path = "[slug]/page.c", text = "" },
]
expect = "true"
]==]
local commands = require("psi.slash_commands")

local function completes(input, expected_prefix, expected_insert, expected_start)
  local result = commands.input_completions(input, #input, 24, false)
  return result and result.prefix == expected_prefix
    and result.start == expected_start
    and #result.items == 1
    and result.items[1].insert == expected_insert
end

return tostring(
  completes("see (src/ma", "src/ma", "src/main.c", 6)
  and completes("see (`src/ma", "src/ma", "src/main.c", 7)
  and completes("see [slug]/pa", "[slug]/pa", "[slug]/page.c", 5)
  and completes("/resume (src/ma", "src/ma", "src/main.c", 10)
  and commands.input_completions("see foo(src/ma", 14, 24, false) == nil
)
