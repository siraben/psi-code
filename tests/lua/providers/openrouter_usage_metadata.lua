--[==[psi-test
expect = "700|200|100|50|0.0125"
]==]
local debug_api = require("psi.providers.openrouter")._debug
local state = debug_api.new_state()
local parser = debug_api.parser_new()
debug_api.parser_push(
  parser,
  [[data: {"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":50,"cost":0.0125,"prompt_tokens_details":{"cached_tokens":200,"cache_write_tokens":100}}}

]],
  state,
  {}
)
return table.concat({
  tostring(state.usage.input_tokens),
  tostring(state.usage.cache_read_input_tokens),
  tostring(state.usage.cache_creation_input_tokens),
  tostring(state.usage.output_tokens),
  tostring(state.usage.cost),
}, "|")
