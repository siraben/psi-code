--[[psi-test
# Original: parts[0] == "false" AND parts[1] >= 1. Folded.
expect = "true|true"
]]
local a = require("psi.providers.anthropic")
local prelude = require("psi.prelude")
local function msg(role, body)
  return { role = role, text = "", data = psi.json_encode(body) }
end
local session = {
  { role = "compaction-summary", text = "old work",
    data = psi.json_encode({ summary = "old work" }) },
  msg("tool-result", { message = {
    role = "toolResult", toolCallId = "toolu_ORPHAN",
    toolName = "bash",
    content = { { type = "text", text = "stale output" } } } }),
  msg("user", { message = { role = "user",
    content = { { type = "text", text = "continue" } } } }),
}
local wire = a._test.build_api_messages(session)
local found = false
for _, m in ipairs(wire) do
  if type(m.content) == "table" then
    for _, b in ipairs(m.content) do
      if type(b) == "table" and b.type == "tool_result"
         and b.tool_use_id == "toolu_ORPHAN" then
        found = true
      end
    end
  end
end
return tostring(not found) .. "|" .. tostring(#wire >= 1)
