-- psi.hooks: default event-hook registrations.

local render = require("psi.render")

render.register_hook("assistant-text", function(payload)
  return payload.text or ""
end)

render.register_hook("tool-call", render.capture_frame)
render.register_hook("tool-call", render.render_tool_call)
render.register_hook("tool-result", render.render_tool_result)
render.register_hook("tool-result", render.release_frame)

render.register_hook("after-turn", function() return "\n" end)
