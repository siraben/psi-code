--[==[psi-test
expect = "hi|0|7|3|nil|true|error|Codex error: bad|true"
]==]
local d = require("psi.providers.openai_codex")._debug
local s, p = d.new_state(), d.parser_new()
local seen = ""
local obs = { on_assistant_text_delta = function(t) seen = seen .. t end }
d.parser_push(p, "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}\n\n", s, obs)
d.parser_push(p, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n", s, obs)
d.parser_push(p, "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"content\":[{\"type\":\"output_text\",\"text\":\"hi\"}]}}\n\n", s, obs)
d.parser_push(p, "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"total_tokens\":12,\"input_tokens_details\":{\"cached_tokens\":3}}}}\n\n", s, obs)
local _, calls = d.finalize(s)
local body = d.request_body({model="gpt-5.5", messages={}, max_tokens=123})
local e, ep = d.new_state(), d.parser_new()
local ok = pcall(d.parser_push, ep, "data: {\"type\":\"error\",\"message\":\"bad\"}\n\n", e, {})
local classified = d.classify_http_error(429, "{\"error\":{\"message\":\"slow\"}}", "openai-codex")
return seen .. "|" .. tostring(#calls) .. "|" .. tostring(s.usage.input_tokens) .. "|"
  .. tostring(s.usage.cache_read_input_tokens) .. "|" .. tostring(body.max_output_tokens) .. "|"
  .. tostring(ok) .. "|" .. tostring(e.stop_reason) .. "|" .. tostring(e.error_message) .. "|"
  .. tostring(classified:find("slow", 1, true) ~= nil)
