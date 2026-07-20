--[==[psi-test
expect = "message_start|content_block_delta|READY"
]==]
-- push_sse surfaces the event type for "event:foo" (no space after the
-- colon), which the Anthropic dispatcher keys on. Some endpoints emit events
-- this way rather than "event: foo".
local sp = require("psi.stream_parser")
local prelude = require("psi.prelude")

local parser = sp.sse_parser()
local events = {}
local texts = {}
local chunk = table.concat({
  "event:message_start",
  'data:{"type":"message_start"}',
  "",
  "event:content_block_delta",
  'data:{"type":"content_block_delta","delta":{"type":"text_delta","text":"READY"}}',
  "",
}, "\n") .. "\n"

sp.push_sse(parser, chunk, {
  multi_data = true,
  on_event = function(ev, data)
    events[#events + 1] = tostring(ev)
    local obj = prelude.safe_json_decode(data)
    if obj and obj.delta and obj.delta.text then
      texts[#texts + 1] = obj.delta.text
    end
  end,
})

return events[1] .. "|" .. events[2] .. "|" .. table.concat(texts)
