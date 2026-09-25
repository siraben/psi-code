--[==[psi-test
expect = "valid=2 malformed=2 preserved=true"
]==]
local session = require("psi.session_manager")
local prelude = require("psi.prelude")

local function run_case(path, malformed)
  psi.session_clear()
  session.reset_entry_chain()
  psi.session_set_path(path)
  session.append_user("before")
  assert(session.save())
  local original = assert(psi.read_file(path))
  assert(original:sub(-1) == "\n")
  if malformed then
    assert(psi.file_write(path, original .. "{incomplete"))
  else
    assert(psi.file_write(path, original:sub(1, -2)))
  end

  assert(session.load(path))
  session.append_user("after")
  assert(session.save())

  local valid_messages = 0
  local malformed_preserved = false
  for line in assert(io.lines(path)) do
    local entry = prelude.safe_json_decode(line)
    if type(entry) == "table" and entry.type == "message" then
      valid_messages = valid_messages + 1
    elseif line == "{incomplete" then
      malformed_preserved = true
    end
  end
  return valid_messages, malformed_preserved
end

local valid_count = run_case(TMP .. "/unterminated-valid.jsonl", false)
local malformed_count, malformed_preserved = run_case(TMP .. "/unterminated-malformed.jsonl", true)
return string.format("valid=%d malformed=%d preserved=%s",
  valid_count, malformed_count, tostring(malformed_preserved))
