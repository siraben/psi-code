-- boot.lua: psi Lua bootstrap. The C layer has already:
--   1. Set package.path to locate lua/psi/*.lua modules.
--   2. Created a `psi` global table populated with FFI primitives.
--
-- We attach subsystem tables onto `psi` so the C bridge can reach
-- them through psi.tools.*, psi.session.*, psi.prompt.*, etc. The
-- public namespace names stay short; underlying file paths mirror
-- pi-mono (e.g. psi.session → psi.session_manager).

-- Runtime tuning: Lua 5.5 keeps generational collection as the best
-- default for psi's allocation-heavy hot paths. Most allocations are
-- short-lived (SSE chunks parsed into tables then discarded, gsub
-- replacement strings, per-line markdown spans, per-tick scratch
-- tables from sched.run_all). Lua 5.5 also gives generational mode
-- incremental major collections, so we get lower churn cost without
-- full stop-the-world majors. Set PSI_GC_MODE to override
-- ("incremental" reverts; "off" disables autocollection entirely).
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
psi.platform = require("psi.platform")
psi.path = require("psi.path_utils")
psi.notice = require("psi.notice")

-- Project-local resources are gated behind workspace trust; resolve it
-- before anything reads ./.psi/* (settings, extensions, prompts).
psi.trust = require("psi.trust")
psi.project_trusted = psi.trust.resolve({ interactive = psi.interactive })
if not psi.project_trusted then
  psi.trust.notice_if_skipped()
end

psi.sched = require("psi.sched")
psi.events = require("psi.event_bus")
psi.ansi = require("psi.ansi")
psi.ansi.autodetect()
psi.diff = require("psi.diff")
psi.records = require("psi.records")
psi.context = require("psi.context")
psi.settings = require("psi.settings_manager")
psi.theme = require("psi.theme")
psi.theme.bootstrap()
psi.providers = require("psi.api_registry")
psi.resources = require("psi.resource_loader")
psi.session = require("psi.session_manager")
psi.tools = require("psi.tools")
psi.mcp = require("psi.mcp")
psi.mcp.bootstrap()
psi.anthropic = require("psi.providers.anthropic")
psi.ollama = require("psi.providers.ollama")
psi.prompt = require("psi.prompt")
psi.keybindings = require("psi.keybindings")
psi.agent = require("psi.agent_session")
psi.agent_runtime = require("psi.agent_session_runtime")
psi.render = require("psi.render")
psi.commands = require("psi.slash_commands")
psi.prompt_templates = require("psi.prompt_templates")
psi.tui = require("psi.tui_status")
psi.tui_layout = require("psi.tui_layout")
psi.extensions = psi.extensions or {}
psi.extensions.osc52_clipboard = require("psi.extensions.osc52_clipboard")
psi.extensions.vim_keybindings = require("psi.extensions.vim_keybindings")

function psi.install_builtin_extensions()
  psi.extensions.osc52_clipboard.register(psi)
  psi.extensions.vim_keybindings.register(psi)
end

psi.install_builtin_extensions()
psi.modes = require("psi.modes")
psi.markdown = require("psi.markdown")

-- Self-documenting registry. Harvests descriptions from existing
-- registries (slash commands, tools, keybindings, providers) plus
-- the C-side PSI_REG_DOC table so /describe and /apropos can work
-- without any new annotation step on each entry's home file.
psi.doc = require("psi.doc")
psi.doc.bootstrap(psi)

local function load_packaged_extension(module_name)
  local ok, ext = pcall(require, module_name)
  if not ok then
    psi.notice.error(
      "psi: packaged extension " .. module_name .. " failed to load: " .. tostring(ext),
      { source = "extension-loader" }
    )
  elseif type(ext) == "function" then
    local inv_ok, inv_err = pcall(ext, psi)
    if not inv_ok then
      psi.notice.error(
        "psi: packaged extension " .. module_name .. " failed during init: " .. tostring(inv_err),
        { source = "extension-loader" }
      )
    end
  end
end

for _, module_name in ipairs({
  "psi.extensions.btw",
}) do
  load_packaged_extension(module_name)
end

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
  if os.getenv("PSI_SHOW_THINKING") == "0" then
    return ""
  end
  local text = payload and payload.text or ""
  if text == "" then
    return ""
  end
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
  "assistant-text",
  "thinking-delta",
  "tool-call",
  "tool-result",
  "before-turn",
  "after-turn",
}) do
  psi.render.register_hook(ev, function(payload)
    psi.events.emit(ev, payload)
    return nil
  end)
end

-- Extension discovery: load Lua files from, in order,
--   $PSI_EXTENSIONS_DIR (colon-separated list)
--   ~/.config/psi/extensions/
--   ./.psi/extensions/  (only when the directory is trusted)
-- Each file is dofile'd; if it returns a function, that function is
-- invoked with the global `psi` table. Failures are logged to stderr
-- but never abort psi.
local function list_lua_files(dir)
  if not dir or dir == "" then
    return {}
  end
  local entries = psi.list_dir(dir)
  if type(entries) ~= "table" then
    return {}
  end
  local names = {}
  for _, name in ipairs(entries) do
    if type(name) == "string" and name:match("%.lua$") then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

local function load_extensions_from(dir)
  for _, name in ipairs(list_lua_files(dir)) do
    local path = psi.path.join(dir, name)
    local ok, ext = pcall(dofile, path)
    if not ok then
      psi.notice.error(
        "psi: extension " .. path .. " failed to load: " .. tostring(ext),
        { source = "extension-loader" }
      )
    elseif type(ext) == "function" then
      local inv_ok, inv_err = pcall(ext, psi)
      if not inv_ok then
        psi.notice.error(
          "psi: extension " .. path .. " failed during init: " .. tostring(inv_err),
          { source = "extension-loader" }
        )
      end
    end
  end
end

function psi.load_extensions()
  local env_dirs = os.getenv("PSI_EXTENSIONS_DIR") or ""
  for dir in (env_dirs .. ":"):gmatch("([^:]*):") do
    if dir ~= "" then
      load_extensions_from(dir)
    end
  end
  local home = os.getenv("HOME")
  if home and home ~= "" then
    load_extensions_from(psi.path.join(home, ".config/psi/extensions"))
  end
  if psi.project_trusted then
    load_extensions_from("./.psi/extensions")
  end
end

if psi.load_user_extensions ~= false then
  psi.load_extensions()
end
psi.theme.apply_configured({ preserve_current = true })
psi.prompt_templates.load()
