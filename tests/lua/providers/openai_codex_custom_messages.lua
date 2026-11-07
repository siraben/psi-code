--[==[psi-test
expect = "2|user|input_text|visible user|message|assistant|output_text|visible assistant"
]==]
local s = require("psi.session_manager")
local d = require("psi.providers.openai_codex")._debug
s.append_custom_message("visible user", { role = "user" })
s.append_custom_message("hidden user", { role = "user", hidden = true })
s.append_custom_message("visible assistant", { role = "assistant" })
local wire = d.response_input_from_session(s.messages(), "")
s.append_custom_message("model-only", { display = false, customType = "note" })
local projected = d.response_input_from_session(s.context_messages(), "")
assert(#projected == 3 and projected[3].role == "user")
assert(projected[3].content[1].text == "model-only", "display controls UI visibility")
local raw = d.response_input_from_session(s.messages(), "")
assert(#raw == 3 and raw[3].content[1].text == "model-only")
return table.concat({
  tostring(#wire),
  wire[1].role,
  wire[1].content[1].type,
  wire[1].content[1].text,
  wire[2].type,
  wire[2].role,
  wire[2].content[1].type,
  wire[2].content[1].text,
}, "|")
