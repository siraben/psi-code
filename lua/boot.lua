-- boot.lua: psi Lua bootstrap. The C layer has already:
--   1. Set package.path to locate lua/psi/*.lua modules.
--   2. Created a `psi` global table populated with FFI primitives.
--
-- We attach subsystem tables onto `psi` so the C bridge can reach them
-- through psi.tools.*, psi.session.*, psi.prompt.*, psi.render.*,
-- psi.commands.*.

psi.prelude   = require("psi.prelude")
psi.ansi      = require("psi.ansi")
psi.diff      = require("psi.diff")
psi.records   = require("psi.records")
psi.context   = require("psi.context")
psi.session   = require("psi.session")
psi.tools     = require("psi.tools")
psi.anthropic = require("psi.anthropic")
psi.prompt    = require("psi.prompt")
psi.agent     = require("psi.agent")
psi.render    = require("psi.render")
psi.commands  = require("psi.commands")
psi.modes     = require("psi.modes")

-- Default event-hook registrations.
psi.render.register_hook("assistant-text", function(payload)
  return payload.text or ""
end)
psi.render.register_hook("tool-call", psi.render.capture_frame)
psi.render.register_hook("tool-call", psi.render.render_tool_call)
psi.render.register_hook("tool-result", psi.render.render_tool_result)
psi.render.register_hook("tool-result", psi.render.release_frame)
psi.render.register_hook("after-turn", function() return "\n" end)

-- Convenience shim so user code can write psi.tool_call(name, input).
function psi.tool_call(name, input)
  return psi.tools.dispatch_alist(name, input)
end
