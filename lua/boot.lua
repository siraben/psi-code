-- boot.lua: psi Lua bootstrap. The C layer has already:
--   1. Set package.path to locate lua/psi/*.lua modules.
--   2. Created a `psi` global table populated with FFI primitives.
--
-- We attach subsystem tables onto `psi` so the C bridge can reach them
-- through psi.tools.*, psi.session.*, psi.prompt.*, psi.render.*,
-- psi.commands.*.

-- Runtime tuning: Lua 5.4's generational GC wins on psi's workload.
-- Most allocations are short-lived (SSE chunks parsed into tables
-- then discarded, gsub replacement strings, per-line markdown
-- spans, per-tick scratch tables from sched.run_all). With
-- incremental the same workload pays ~15% more than with
-- generational on the hot paths that churn. Set PSI_GC_MODE to
-- override ("incremental" reverts; "off" disables autocollection
-- entirely — don't do this unless you know what you want).
do
  local mode = os.getenv("PSI_GC_MODE")
  if mode == "off" then
    collectgarbage("stop")
  elseif mode == "incremental" then
    collectgarbage("incremental")
  else
    collectgarbage("generational")
  end
end

psi.prelude = require("psi.prelude")
psi.sched = require("psi.sched")
psi.events = require("psi.events")
psi.ansi = require("psi.ansi")
psi.ansi.autodetect()
psi.diff = require("psi.diff")
psi.records = require("psi.records")
psi.context = require("psi.context")
psi.settings = require("psi.settings")
psi.providers = require("psi.providers")
psi.resources = require("psi.resources")
psi.session = require("psi.session")
psi.tools = require("psi.tools")
psi.anthropic = require("psi.anthropic")
psi.ollama = require("psi.ollama")
psi.prompt = require("psi.prompt")
psi.agent = require("psi.agent")
psi.render = require("psi.render")
psi.commands = require("psi.commands")
psi.prompt_templates = require("psi.prompt_templates")
psi.tui = require("psi.tui")
psi.tui_layout = require("psi.tui_layout")
psi.modes = require("psi.modes")
psi.markdown = require("psi.markdown")

-- Default event-hook registrations.
--
-- Assistant text flows through a line-buffered markdown stream when
-- PSI_MARKDOWN is not explicitly disabled. The stream accumulates
-- partial lines between deltas; only complete lines emerge styled.
-- after-turn flushes any trailing partial line.
local md_enabled = (os.getenv("PSI_MARKDOWN") ~= "0")
local md_stream = md_enabled and psi.markdown.new_stream() or nil

psi.render.register_hook("assistant-text", function(payload)
  -- When assistant text resumes after a tool result, pi leaves one
  -- blank line between the tool result and the new text. psi's stream
  -- deltas don't end in "\n", so we emit a leading "\n" only on the
  -- first delta of the new text block.
  local sep = psi.render.last_event_kind() == "tool-result" and "\n" or ""
  local text = payload.text or ""
  if md_stream then
    text = md_stream:feed(text)
  end
  return sep .. text
end)

psi.render.register_hook("after-turn", function()
  if md_stream then
    local tail = md_stream:flush()
    -- Reset fence state across turns so a mid-turn unbalanced ``` does
    -- not bleed into the next turn.
    md_stream.state.in_code_fence = false
    if tail ~= "" then
      return tail
    end
  end
  return ""
end)
psi.render.register_hook("tool-call", psi.render.capture_frame)
psi.render.register_hook("tool-call", psi.render.render_tool_call)
psi.render.register_hook("tool-result", psi.render.render_tool_result)
psi.render.register_hook("tool-result", psi.render.release_frame)
psi.render.register_hook("after-turn", function()
  return "\n"
end)

-- Default renderer for reasoning-model thinking in non-TUI modes.
-- Qwen3, DeepSeek-R1, and similar models emit a separate thinking
-- stream before (or instead of) visible content; without this hook
-- REPL / --agent / --print would swallow it entirely and look hung.
-- Wrap the stream in dim italics with a one-shot "thinking:" label
-- so the reasoning is visible but visually distinct from the final
-- answer. Opt out with PSI_SHOW_THINKING=0.
local thinking_shown = false
psi.render.register_hook("thinking-delta", function(payload)
  if os.getenv("PSI_SHOW_THINKING") == "0" then return "" end
  local text = payload and payload.text or ""
  if text == "" then return "" end
  local pre = thinking_shown and "" or (psi.ansi.dim("thinking: "))
  thinking_shown = true
  return pre .. psi.ansi.dim(text)
end)
psi.render.register_hook("after-turn", function()
  -- Reset the one-shot label so the next turn's thinking gets its
  -- own header. Also flush a blank line if thinking was shown, to
  -- separate it from the final answer.
  if thinking_shown then
    thinking_shown = false
    return "\n"
  end
  return ""
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
  "assistant-text", "thinking-delta",
  "tool-call", "tool-result", "before-turn", "after-turn",
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
  -- pcall the read loop so an interrupted read (rare; most commonly
  -- a Lua error in the ipairs walk below) still closes the popen
  -- descriptor. Without this, repeated load_extensions() calls —
  -- e.g. via /reload — would gradually leak pipe fds until the
  -- process hit EMFILE.
  local names = {}
  pcall(function()
    for line in handle:lines() do
      if line:match("%.lua$") then names[#names + 1] = line end
    end
  end)
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
psi.prompt_templates.load()
