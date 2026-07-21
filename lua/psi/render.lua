-- psi.render: hooks, tool-frame tracking, event rendering.

local records = require("psi.records")
local prelude = require("psi.prelude")
local tool_execution = require("psi.tui_components.tool_execution")

local M = {}

-- ---------- hooks ----------

local hooks = {}

-- Event catalog. The keys here are the names the hook-dispatch path
-- (modes.fire / handle_event) emits. Exposed via M.events() so
-- extensions can discover what's hookable without grep. Keep in sync
-- with docs/extensions.md §"Event catalog" and with the fire() sites
-- in psi.modes / psi.anthropic / psi.session.
local event_catalog = {
  "before-turn",
  "assistant-text",
  "thinking-delta",
  "tool-call",
  "tool-result",
  "after-turn",
}

function M.events()
  local out = {}
  for i, name in ipairs(event_catalog) do
    out[i] = name
  end
  return out
end

function M.register_hook(event, fn)
  hooks[event] = hooks[event] or {}
  local chain = hooks[event]
  chain[#chain + 1] = fn
end

function M.run_hooks(event, payload)
  local results = {}
  local chain = hooks[event]
  if not chain then
    return results
  end
  for _, fn in ipairs(chain) do
    results[#results + 1] = fn(payload)
  end
  return results
end

-- A hook may return one of:
--   nil / false       → contribute nothing (observer-style)
--   "string"          → append to the running render
--   {replace=true,
--    text="..."}      → DISCARD everything accumulated so far by
--                       earlier hooks in this chain and start over
--                       with `text`. Subsequent hooks in the chain
--                       still append. Use this when you want to
--                       override a built-in renderer (e.g. replace
--                       read's default tool-result block with a
--                       numbered one). The last replace wins among
--                       the chain.
local function render_hook_results(results)
  local pieces = {}
  local replaced = false
  for _, item in ipairs(results) do
    if type(item) == "string" then
      pieces[#pieces + 1] = item
    elseif type(item) == "table" and item.replace then
      replaced = true
      pieces = { item.text or "" }
    end
  end
  return table.concat(pieces), replaced
end

-- Track which event we rendered most recently so hooks can compute
-- blank-line separators without global output buffers. The value is
-- updated AFTER the current event's hooks run, so hooks see the
-- previous event's kind. Reset on each new turn via "before-turn".
local last_event_kind = "before-turn"

function M.last_event_kind()
  return last_event_kind
end

function M.handle_event(event, payload)
  local text = render_hook_results(M.run_hooks(event, payload))
  last_event_kind = event
  return text
end

function M.handle_event_details(event, payload)
  local text, replaced = render_hook_results(M.run_hooks(event, payload))
  last_event_kind = event
  return text, replaced
end

-- ---------- tool frames ----------

local frames = {}

function M.store_frame(id, frame)
  frames[id] = frame
end
function M.lookup_frame(id)
  return frames[id]
end
function M.remove_frame(id)
  frames[id] = nil
end

-- ---------- payload helpers ----------

local function payload_tool(p)
  return p.tool
end

local function payload_id(p)
  return p.id
end

local function payload_input(p)
  return p.input or {}
end

local function payload_result(p)
  return records.tool_result_from_alist(p.result or {})
end

-- pi-mono inserts a `Spacer(1)` before each independent tool block.
-- Consecutive call/result events are rendered as one visual group.
local function tool_block_leading()
  local kind = M.last_event_kind()
  if kind == "tool-call" or kind == "tool-result" then
    return ""
  end
  return "\n"
end

local function now_ms()
  if type(psi) == "table" and type(psi.time_ms) == "function" then
    return psi.time_ms()
  end
  return nil
end

-- ---------- dispatch ----------

function M.render_tool_call(p)
  local tool = payload_tool(p)
  local id = payload_id(p)
  local frame = id and M.lookup_frame(id) or nil
  return tool_block_leading() .. tool_execution.render_call(tool, payload_input(p), frame)
end

function M.render_tool_result(p)
  local tool = payload_tool(p)
  local id = payload_id(p)
  local frame = id and M.lookup_frame(id) or nil
  return tool_execution.render_result(tool, payload_result(p), frame)
end

-- ---------- frame capture/release ----------

function M.capture_frame(p)
  local tool = payload_tool(p)
  local input = payload_input(p)
  local id = payload_id(p)
  local path = input.path
  local before_text
  if path and (tool == "write" or tool == "edit") then
    before_text = prelude.safe_read(path)
  end
  if id then
    local frame = records.new_tool_frame(tool, input, path, before_text)
    frame.started_ms = now_ms()
    M.store_frame(id, frame)
  end
  return nil
end

function M.release_frame(p)
  local id = payload_id(p)
  if id then
    M.remove_frame(id)
  end
  return nil
end

return M
