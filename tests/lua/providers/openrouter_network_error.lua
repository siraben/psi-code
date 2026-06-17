--[==[psi-test
expect = "hello|network_error|true"
]==]
local d = require("psi.providers.openrouter")._debug
local cfg = d.make_config("test/model")
local state = d.new_state()
local parser = d.parser_new()
local seen = ""
local observer = {
  on_assistant_text_delta = function(text)
    seen = seen .. text
  end,
}

d.parser_push(parser, "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n", state, observer)
d.parser_push(parser, "data: {\"choices\":[{\"finish_reason\":\"network_error\"}]}\n\n", state, observer)

local err = cfg.stream_error(state)
return seen .. "|" .. tostring(state.stop_reason) .. "|"
  .. tostring(type(err) == "string" and err:find("network_error", 1, true) ~= nil)
