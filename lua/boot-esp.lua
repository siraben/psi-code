-- boot-esp.lua: slim bootstrap for embedded targets (ESP32 et al.).
--
-- Same shape as boot.lua but skips the modules an embedded agent
-- doesn't need: TUI, slash commands, secondary providers, markdown
-- rendering, theming, prompt-template discovery, on-disk extensions.
-- Selected by psi_vm_init when no host filesystem is present and the
-- embedded table has this module. Desktop boot.lua is unchanged.
--
-- The streaming output path on embedded targets is the C observer
-- installed by psi_vm_run_agent_turn — it bypasses psi.render
-- entirely, so we don't register the render hooks that boot.lua
-- wires up for stdio output.

do
  local mode = os.getenv and os.getenv("PSI_GC_MODE") or nil
  if mode == "off" then
    collectgarbage("stop")
  elseif mode == "incremental" then
    collectgarbage("incremental")
  else
    collectgarbage("generational")
  end
end

-- Storage routing first so subsequent modules see prefix-aware
-- psi.file_* primitives instead of the raw POSIX ones (which on
-- ESP don't exist anyway). The shims also lock down io.open /
-- loadfile / dofile to @mem and @embedded.
psi.ramfs = require("psi.ramfs")
psi.storage = require("psi.storage")

psi.prelude = require("psi.prelude")
psi.path = require("psi.path_utils")
psi.sched = require("psi.sched")
psi.events = require("psi.event_bus")
psi.diff = require("psi.diff")
psi.records = require("psi.records")
psi.context = require("psi.context")
psi.providers = require("psi.api_registry")
psi.session = require("psi.session_manager")
psi.tools = require("psi.tools")
psi.anthropic = require("psi.providers.anthropic")
psi.prompt = require("psi.prompt")
psi.agent = require("psi.agent_session")
-- render and modes are needed when the desktop CLI dispatcher runs
-- this boot (PSI_CAP_FILESYSTEM=0 desktop test mode). The ESP
-- entrypoint never calls psi.modes.run; it drives the agent directly
-- through psi_vm_run_agent_turn so the C observer bypasses render.
-- ansi/render are tiny so the cost of loading them is negligible.
psi.ansi = require("psi.ansi")
psi.ansi.autodetect()
psi.render = require("psi.render")
psi.modes = require("psi.modes")

function psi.tool_call(name, input)
  return psi.tools.dispatch_alist(name, input)
end
