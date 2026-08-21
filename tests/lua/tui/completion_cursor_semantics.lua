--[==[psi-test
cwd = "proj"
files = [
  { path = "src/main.c", text = "int main(void){return 0;}" },
]
expect = "/thinking high tail|14||src/main.c tail|10|||true"
]==]
local rt = require("psi.tui_runtime")

-- Enter accepts command arguments without submitting, and keeps text after
-- the cursor in place.
local argument = rt._debug_edit_keys("/thinking h tail", 11, { { key = "enter" } }, false)

-- Direct path completion has the same acceptance semantics, including when
-- the cursor is in the middle of the buffer.
local path = rt._debug_edit_keys("src/ma tail", 6, { { key = "enter" } }, false)

-- A slash command-name completion deliberately falls through Enter to the
-- command dispatcher, matching pi's editor.
local command = rt._debug_edit_keys("/he", 3, { { key = "enter" } }, false)

return table.concat({
  argument.input,
  tostring(argument.cursor),
  argument.last_entry_kind or "",
  path.input,
  tostring(path.cursor),
  path.last_entry_kind or "",
  command.input,
  tostring(
    command.last_entry_text and command.last_entry_text:find("available commands", 1, true) ~= nil
  ),
}, "|")
