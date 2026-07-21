--[==[psi-test
expect = "before:hello,delta:streamed,after:true,shutdown|true|true|true"
files = [
  { path = "turn.jsonl", text = "" },
]
]==]
local seen = {}
psi.events.on("session-shutdown", function()
  seen[#seen + 1] = "shutdown"
end)

local agent = require("psi.agent_session")
local original_run_turn = agent.run_turn
agent.run_turn = function(opts)
  opts.observer.on_assistant_text_delta("streamed")
  require("psi.session_manager").append_assistant(
    "streamed",
    { { type = "text", text = "streamed" } },
    {}
  )
  return true, "streamed"
end

local runtime = require("psi.agent_session_runtime").new({
  session_file = TMP .. "/turn.jsonl",
})
local started = runtime:bootstrap()
local ok, _, result = runtime:turn("hello", {
  observer = {
    on_assistant_text_delta = function(text)
      seen[#seen + 1] = "delta:" .. text
    end,
  },
  before_turn = function(payload)
    seen[#seen + 1] = "before:" .. payload.text
  end,
  after_turn = function(payload)
    seen[#seen + 1] = "after:" .. tostring(payload["assistant-streamed"])
  end,
})
runtime:shutdown()
agent.run_turn = original_run_turn

local saved = psi.read_file(TMP .. "/turn.jsonl") or ""
return table.concat(seen, ",")
  .. "|"
  .. tostring(started)
  .. "|"
  .. tostring(ok and result.save_ok)
  .. "|"
  .. tostring(saved:find('"streamed"', 1, true) ~= nil)
