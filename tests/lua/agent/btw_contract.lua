--[==[psi-test
expect = "true|answer|true|true|true|true|true|true|true|0|true|true"
]==]
local agent = require("psi.agent_session")
local session = require("psi.session_manager")
local ollama = require("psi.providers.ollama")

psi.session_clear()
agent.clear_queues()
agent.configure({ model = "ollama/qwen2.5" })

local captured = nil
ollama.complete_text = function(opts)
  captured = opts
  return true, "answer"
end

session.append_user("main transcript")
local before = psi.session_message_count()
local ok, answer = agent.side_question("side?", {
  max_tokens = 99,
  abort_check = function()
    return true
  end,
})
local after = psi.session_message_count()

local empty_capture = nil
ollama.complete_text = function(opts)
  empty_capture = opts
  return true, "empty"
end
psi.session_clear()
local empty_ok = agent.side_question("empty?")

return table.concat({
  tostring(ok),
  tostring(answer),
  tostring(captured.model == "qwen2.5"),
  tostring(captured.max_tokens == 99),
  tostring(captured.abort_check()),
  tostring(captured.tool_specs == nil),
  tostring(captured.system_prompt:find("cannot call tools", 1, true) ~= nil),
  tostring(captured.system_prompt:find("Available tools", 1, true) == nil),
  tostring(captured.user_text:find("main transcript", 1, true) ~= nil),
  tostring(after - before),
  tostring(empty_ok),
  tostring(empty_capture.user_text:find("(empty transcript)", 1, true) ~= nil),
}, "|")
