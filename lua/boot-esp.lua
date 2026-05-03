-- boot-esp.lua: minimal ESP32 bootstrap.
--
-- Loads the modules an embedded agent needs, with a forced GC pass
-- between each so the temporary inflate buffers don't pile up.
-- Skips the desktop boot's TUI / extensions / multi-provider /
-- markdown / theme / slash_commands / modes — none of those are used
-- by the C-driven psi_vm_run_agent_turn entrypoint.

collectgarbage("generational")

local function load_module(name)
    local m = require(name)
    collectgarbage("collect")
    return m
end

-- Storage routing first; subsequent modules see prefix-aware
-- psi.file_* primitives instead of (absent) host primitives.
psi.ramfs = load_module("psi.ramfs")
psi.storage = load_module("psi.storage")

psi.prelude = load_module("psi.prelude")
psi.path = load_module("psi.path_utils")
psi.sched = load_module("psi.sched")
psi.records = load_module("psi.records")
psi.providers = load_module("psi.api_registry")
psi.session = load_module("psi.session_manager")
psi.tools = load_module("psi.tools")
psi.prompt = load_module("psi.prompt")
psi.anthropic = load_module("psi.providers.anthropic")
psi.agent = load_module("psi.agent_session")

-- Stub primitives that the desktop boot expects but the
-- filesystem-capability gate compiled out. resource_loader.lua walks
-- the cwd looking for context files; on ESP there's no working
-- directory, so return "/" and the loader naturally finds nothing.
if psi.cwd == nil then
    psi.cwd = function() return "/" end
end

function psi.tool_call(name, input)
    return psi.tools.dispatch_alist(name, input)
end

collectgarbage("collect")
