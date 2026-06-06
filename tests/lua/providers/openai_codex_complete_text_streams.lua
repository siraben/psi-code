--[==[psi-test
expect = "true|hi|true|nil|nil|nil"
env = { PSI_AUTH_FILE = "{TMP}/codex-auth.json" }
]==]
local auth = require("psi.auth_storage")
auth.set("openai-codex", {
  type = "oauth",
  access = "a",
  refresh = "r",
  expires = 9999999999999,
  accountId = "acct",
})

local captured = nil
local chunks = {
  'data: {"type":"response.output_item.added","item":{"type":"message","id":"msg_1"}}\n\n',
  'data: {"type":"response.output_text.delta","delta":"hi"}\n\n',
  'data: {"type":"response.output_item.done","item":{"type":"message","id":"msg_1","content":[{"type":"output_text","text":"hi"}]}}\n\n',
  'data: {"type":"response.completed","response":{"status":"completed"}}\n\n',
}
local i = 0
psi.http_stream_begin = function(_url, _headers, body)
  captured = psi.json_decode(body)
  return {}
end
psi.http_stream_poll = function()
  i = i + 1
  return chunks[i], i >= #chunks
end
psi.http_stream_finish = function()
  return 200
end

local ok, text = require("psi.sched").run(function()
  return require("psi.providers.openai_codex").complete_text({
    model = "gpt-5.5",
    system_prompt = "s",
    user_text = "u",
  })
end)
return table.concat({
  tostring(ok),
  tostring(text),
  tostring(captured and captured.stream),
  tostring(captured and captured.tools),
  tostring(captured and captured.tool_choice),
  tostring(captured and captured.parallel_tool_calls),
}, "|")
