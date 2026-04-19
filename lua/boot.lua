-- boot.lua: psi Lua bootstrap. The C layer has already:
--   1. Set package.path to locate lua/psi/*.lua modules.
--   2. Created a `psi` global table populated with FFI primitives.
--
-- We attach subsystem tables onto `psi` so the C bridge can reach them
-- through psi.tools.*, psi.session.*, psi.prompt.*, psi.render.*,
-- psi.commands.*.

psi.prelude  = require("psi.prelude")
psi.ansi     = require("psi.ansi")
psi.io       = require("psi.io")
psi.diff     = require("psi.diff")
psi.records  = require("psi.records")
psi.session  = require("psi.session")
psi.tools    = require("psi.tools")
psi.prompt   = require("psi.prompt")
psi.render   = require("psi.render")
psi.commands = require("psi.commands")
require("psi.hooks")

-- Convenience shim so user code can write psi.tool_call(name, input).
function psi.tool_call(name, input)
  return psi.tools.dispatch_alist(name, input)
end
