-- boot.lua: psi Lua bootstrap. The C layer has already:
--   1. Set package.path to locate lua/psi/*.lua modules.
--   2. Created a `psi` global table populated with FFI primitives.
--
-- We attach subsystem tables onto `psi` so the C bridge can reach them
-- through psi.tools.*, psi.session.*, psi.prompt.*, psi.render.*,
-- psi.commands.*.

psi.prelude = require("psi.prelude")
psi.events = require("psi.events")
psi.ansi = require("psi.ansi")
psi.diff = require("psi.diff")
psi.records = require("psi.records")
psi.context = require("psi.context")
psi.session = require("psi.session")
psi.tools = require("psi.tools")
psi.anthropic = require("psi.anthropic")
psi.ollama = require("psi.ollama")
psi.prompt = require("psi.prompt")
psi.agent = require("psi.agent")
psi.render = require("psi.render")
psi.commands = require("psi.commands")
psi.tui = require("psi.tui")
psi.modes = require("psi.modes")

-- Default event-hook registrations.
psi.render.register_hook("assistant-text", function(payload)
  -- When assistant text resumes after a tool result, pi leaves one
  -- blank line between the tool result and the new text. psi's stream
  -- deltas don't end in "\n", so we emit a leading "\n" only on the
  -- first delta of the new text block (subsequent deltas see the
  -- previous event as "assistant-text").
  local sep = psi.render.last_event_kind() == "tool-result" and "\n" or ""
  return sep .. (payload.text or "")
end)
psi.render.register_hook("tool-call", psi.render.capture_frame)
psi.render.register_hook("tool-call", psi.render.render_tool_call)
psi.render.register_hook("tool-result", psi.render.render_tool_result)
psi.render.register_hook("tool-result", psi.render.release_frame)
psi.render.register_hook("after-turn", function()
  return "\n"
end)

-- Convenience shim so user code can write psi.tool_call(name, input).
function psi.tool_call(name, input)
  return psi.tools.dispatch_alist(name, input)
end

-- Bridge render events onto psi.events. Extensions subscribe with
-- psi.events.on(name, fn); the render bus is preserved untouched
-- because each bridge handler returns nil (contributes "" to the
-- string-concat contract).
for _, ev in ipairs({
  "assistant-text", "tool-call", "tool-result", "before-turn", "after-turn",
}) do
  psi.render.register_hook(ev, function(payload)
    psi.events.emit(ev, payload)
    return nil
  end)
end

-- Extension discovery: load Lua files from, in order,
--   $PSI_EXTENSIONS_DIR (colon-separated list)
--   ~/.config/psi/extensions/
--   ./.psi/extensions/
-- Each file is dofile'd; if it returns a function, that function is
-- invoked with the global `psi` table. Failures are logged to stderr
-- but never abort psi.
local function list_lua_files(dir)
  if not dir or dir == "" then return {} end
  local quoted = "'" .. dir:gsub("'", "'\\''") .. "'"
  local ok, handle = pcall(io.popen, "ls -1 " .. quoted .. " 2>/dev/null")
  if not ok or not handle then return {} end
  local names = {}
  for line in handle:lines() do
    if line:match("%.lua$") then names[#names + 1] = line end
  end
  handle:close()
  table.sort(names)
  return names
end

local function load_extensions_from(dir)
  for _, name in ipairs(list_lua_files(dir)) do
    local path = dir .. "/" .. name
    local ok, ext = pcall(dofile, path)
    if not ok then
      io.stderr:write("psi: extension " .. path .. " failed to load: "
        .. tostring(ext) .. "\n")
    elseif type(ext) == "function" then
      local inv_ok, inv_err = pcall(ext, psi)
      if not inv_ok then
        io.stderr:write("psi: extension " .. path .. " failed during init: "
          .. tostring(inv_err) .. "\n")
      end
    end
  end
end

function psi.load_extensions()
  local env_dirs = os.getenv("PSI_EXTENSIONS_DIR") or ""
  for dir in (env_dirs .. ":"):gmatch("([^:]*):") do
    if dir ~= "" then load_extensions_from(dir) end
  end
  local home = os.getenv("HOME")
  if home and home ~= "" then
    load_extensions_from(home .. "/.config/psi/extensions")
  end
  load_extensions_from("./.psi/extensions")
end

psi.load_extensions()
