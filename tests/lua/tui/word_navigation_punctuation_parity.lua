--[==[psi-test
expect = "foo.bar:4:foo.|foo.bar:3:foo.|path/to/file:8:path/to/|path/to/file:7:path/to/|foo...bar:6:foo...|foo...bar:3:foo..."
]==]
local rt = require("psi.tui_runtime")

local function cursor_after(input, cursor, key)
  return rt._debug_edit_keys(input, cursor, {{key=key}}, false).cursor
end

local function delete_after(input, cursor, key)
  return rt._debug_edit_keys(input, cursor, {{key=key}}, false).input
end

return table.concat({
  "foo.bar:" .. cursor_after("foo.bar", 7, "alt-b") .. ":" .. delete_after("foo.bar", 7, "alt-backspace"),
  "foo.bar:" .. cursor_after("foo.bar", 4, "alt-b") .. ":" .. delete_after("foo.bar", 4, "alt-d"),
  "path/to/file:" .. cursor_after("path/to/file", 12, "alt-b") .. ":" .. delete_after("path/to/file", 12, "alt-backspace"),
  "path/to/file:" .. cursor_after("path/to/file", 8, "alt-b") .. ":" .. delete_after("path/to/file", 8, "alt-d"),
  "foo...bar:" .. cursor_after("foo...bar", 9, "alt-b") .. ":" .. delete_after("foo...bar", 9, "alt-backspace"),
  "foo...bar:" .. cursor_after("foo...bar", 6, "alt-b") .. ":" .. delete_after("foo...bar", 6, "alt-d"),
}, "|")
