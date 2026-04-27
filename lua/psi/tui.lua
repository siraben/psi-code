-- psi.tui: helpers for the C-side TUI to render things that depend
-- on Lua-owned state (session, context, usage). Kept tiny and
-- side-effect-free so the C layer can call them on every redraw.

local context = require("psi.context")
local ansi = require("psi.ansi")
local prelude = require("psi.prelude")
local settings = require("psi.settings")

local M = {}
local BAR_SPLIT = string.char(31)
local busy_rng_seeded = false
local DEFAULT_BUSY_LABELS = {
  "gooning",
  "lowkirkuinely",
  "trolling",
  "rewriting in rust",
  "type error",
  "nix building",
  "hallucinating",
}

-- Status-line hooks. Extensions can register fns that return a short
-- string appended to the TUI status line. Called on every redraw, so
-- they must be cheap and side-effect-free. Return nil / "" to skip.
--
-- Example:
--   psi.tui.register_status_hook(function()
--     return "ext:tps " .. last_tps_value
--   end)
--
-- This is the lightest-weight TUI widget slot: no C plumbing, works
-- in the existing single status-line layout, and is automatically
-- suppressed when a status message (set via psi_tui_set_status) is
-- active. For a dedicated row with arbitrary content, wait for a
-- real widget API — this is the pi-gap shim.
local status_hooks = {}

function M.register_status_hook(fn)
  status_hooks[#status_hooks + 1] = fn
end

function M.clear_status_hooks()
  status_hooks = {}
end

local function short_id(id)
  if type(id) ~= "string" or id == "" then
    return "-"
  end
  return id:sub(1, 8)
end

local function label(text)
  return ansi.color("2", tostring(text or ""))
end

local function value(text)
  return ansi.color("37", tostring(text or ""))
end

local function accent(text)
  return ansi.color("1;36", tostring(text or ""))
end

local function sep()
  return label("  •  ")
end

local function pair(key, val, use_accent)
  return label(key) .. " " .. ((use_accent and accent or value)(val))
end

local function seed_busy_rng()
  if busy_rng_seeded then
    return
  end
  math.randomseed(os.time(), math.floor((os.clock() % 1) * 1000000))
  math.random()
  math.random()
  busy_rng_seeded = true
end

local function configured_busy_labels()
  local configured = settings.get("tui.busy_labels", settings.get("tui.working_words", nil))
  if type(configured) == "string" and configured ~= "" then
    return { configured }
  end
  if type(configured) == "table" then
    local labels = {}
    for _, label_text in ipairs(configured) do
      if type(label_text) == "string" and label_text ~= "" then
        labels[#labels + 1] = label_text
      end
    end
    if #labels > 0 then
      return labels
    end
  end
  return DEFAULT_BUSY_LABELS
end

local function split_path(path)
  local parts = {}
  for part in tostring(path or ""):gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

local function tilde_path(path)
  local home = os.getenv("HOME")
  if type(path) ~= "string" or path == "" then
    return path
  end
  if type(home) == "string" and home ~= "" and path:sub(1, #home) == home then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

local function status_model(arg)
  local ok, agent = pcall(require, "psi.agent")
  return (ok and agent.current_model(arg.model)) or arg.model or "?"
end

local function status_right_parts(model, include_hooks)
  local parts = {
    pair("model", model, false),
    pair("messages", tostring(psi.session_message_count()), false),
  }
  if include_hooks then
    for _, fn in ipairs(status_hooks) do
      local ok_hook, extra = pcall(fn)
      if ok_hook and type(extra) == "string" and extra ~= "" then
        parts[#parts + 1] = extra
      end
    end
  end
  return parts
end

function M.status_bar(arg_json)
  local arg = prelude.safe_json_decode(arg_json, {})
  local model = status_model(arg)
  local left = pair("session", short_id(psi.session_id()), true)
  local right = table.concat(status_right_parts(model, true), sep())
  return left .. BAR_SPLIT .. right
end

-- Format a pi-ish status line. `arg_json` is a JSON object emitted by
-- the C TUI: {model=string, busy=bool, scroll=int}.
-- Returns a single string with fields separated by two spaces.
function M.status_line(arg_json)
  local arg = prelude.safe_json_decode(arg_json, {})
  local model = status_model(arg)
  local busy = arg.busy
  local scroll = tonumber(arg.scroll) or 0
  local parts = {}
  parts[#parts + 1] = pair("session", short_id(psi.session_id()), true)
  for _, right_part in ipairs(status_right_parts(model, true)) do
    parts[#parts + 1] = right_part
  end

  local last = context.last_usage()
  if last and last.total and last.total > 0 then
    local window = context.context_window(model)
    local pct = math.floor((last.total / window) * 100)
    parts[#parts + 1] = pair(
      "context",
      string.format("%d%% (%d/%d)", pct, last.total, window),
      false
    )
  end

  if scroll > 0 then
    parts[#parts + 1] = pair("scroll", tostring(scroll), false)
  end
  if busy then
    parts[#parts + 1] = pair("state", "working", true)
  end
  return table.concat(parts, sep())
end

-- Short help line for the footer. Content depends on mode.
function M.footer_hint(arg_json)
  local arg = prelude.safe_json_decode(arg_json, {})
  if arg.busy then
    return pair("interrupt", "Esc", true) .. sep() .. pair("state", "current turn is live", false)
  end
  return ""
end

function M.workspace_line(cwd)
  local parts = split_path(cwd)
  local repo = nil
  local worktree = nil
  for index = 1, #parts - 1 do
    if parts[index] == ".worktrees" then
      repo = parts[index - 1]
      worktree = parts[index + 1]
      break
    end
  end
  if repo ~= nil and worktree ~= nil then
    return pair("repo", repo, false) .. sep() .. pair("worktree", worktree, true)
  end
  return pair("cwd", tilde_path(cwd or "-"), false)
end

function M.workspace_bar(cwd)
  local parts = split_path(cwd)
  local repo = nil
  local worktree = nil
  for index = 1, #parts - 1 do
    if parts[index] == ".worktrees" then
      repo = parts[index - 1]
      worktree = parts[index + 1]
      break
    end
  end
  if repo ~= nil and worktree ~= nil then
    return pair("repo", repo, false) .. BAR_SPLIT .. pair("worktree", worktree, true)
  end
  return pair("cwd", tilde_path(cwd or "-"), false) .. BAR_SPLIT .. ""
end

function M.render_busy_status(label_text)
  local text = tostring(label_text or "working")
  local chip = ansi.color("1;30;46", " working ")
  return chip .. accent(" " .. text) .. label("  esc to interrupt")
end

function M.pick_busy_status()
  local labels = configured_busy_labels()
  seed_busy_rng()
  return M.render_busy_status(labels[math.random(#labels)])
end

return M
