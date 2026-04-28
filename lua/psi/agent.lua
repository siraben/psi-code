-- psi.agent: high-level turn/compact orchestrators.
--
-- These live in Lua so the C layer is left with only VM lifecycle +
-- HTTP primitives. C calls run_turn / run_compact via the
-- psi_vm_run_agent_* bridge helpers; everything downstream (session ↔
-- API message mapping, tool loop, compaction assembly) is pure Lua.

local context = require("psi.context")
local control = require("psi.agent_control")
local prompt = require("psi.prompt")
local sched = require("psi.sched")
local session = require("psi.session")
local thinking = require("psi.thinking")
local providers = require("psi.providers")

local M = {}

-- ---------- Provider routing ----------
--
-- Selection rules, in priority:
--   1. Explicit model prefix: "ollama/<name>", "anthropic/<name>",
--      or "openrouter/<provider>/<name>" strips the first path
--      segment and routes accordingly. For openrouter we keep the
--      rest of the path — OpenRouter model slugs are
--      "<vendor>/<model>" (e.g. google/gemini-3-flash-preview).
--   2. $PSI_PROVIDER env ("ollama" | "anthropic" | "openrouter").
--   3. Default: anthropic.
local function pick_provider(model)
  local resolved = providers.resolve_descriptor(model)
  return providers.load_provider(providers.provider(resolved.provider)), resolved
end

function M.provider_for(model)
  local provider, resolved = pick_provider(model)
  return provider, resolved.id
end

function M.model_descriptor(fallback)
  return providers.resolve_descriptor(M.current_model(fallback))
end

-- Runtime model switch. Extensions (or a slash command) can call
-- M.set_model("openrouter/google/gemini-3-flash-preview") at any
-- time; subsequent turns resolve to the new model, including the
-- prefix-based provider choice. Pass nil to clear the override and
-- fall back to whatever the C host passed via
-- psi_agent_runtime_configure (CLI --model / $PSI_MODEL).
--
-- Reading from psi.tui.status_line picks this up automatically so
-- the TUI footer reflects the live model string.
local override_model = nil
local override_reasoning_effort = nil

local function normalize_reasoning_effort(value)
  if value == nil then
    return nil
  end
  value = tostring(value):lower()
  if value == "" then
    return nil
  end
  if value == "none" or value == "off" then
    return "none"
  end
  return thinking.normalize(value)
end

local function effort_to_thinking(value)
  value = normalize_reasoning_effort(value)
  if value == "none" then
    return "off"
  end
  return value
end

function M.set_model(name)
  if name == nil or name == "" then
    override_model = nil
  else
    override_model = name
  end
end

function M.current_model(fallback)
  if override_model ~= nil then
    return override_model
  end
  return fallback
end

function M.set_reasoning_effort(value)
  override_reasoning_effort = normalize_reasoning_effort(value)
end

function M.current_reasoning_effort(fallback)
  if override_reasoning_effort ~= nil then
    return override_reasoning_effort
  end
  return normalize_reasoning_effort(fallback)
end

function M.effective_model(fallback)
  local resolved = M.model_descriptor(fallback)
  return resolved and resolved.id
end

local function provider_env_thinking(model)
  local global = os.getenv("PSI_THINKING")
  if global and global ~= "" then
    return global
  end
  if type(model) == "table" and model.provider == "openai-codex" then
    local codex = os.getenv("PSI_OPENAI_CODEX_REASONING")
    if codex == "none" then
      return "off"
    end
    if codex and codex ~= "" then
      return codex
    end
  end
  return nil
end

local function requested_thinking(explicit, reasoning_effort, model)
  if explicit ~= nil and explicit ~= "" then
    return explicit
  end
  if override_reasoning_effort ~= nil then
    return effort_to_thinking(override_reasoning_effort)
  end
  local from_effort = effort_to_thinking(reasoning_effort)
  if from_effort ~= nil then
    return from_effort
  end
  local saved = session.current_thinking_level()
  if saved ~= nil and saved ~= "" then
    return saved
  end
  return provider_env_thinking(model)
end

function M.thinking_level_for(model, explicit, reasoning_effort)
  return thinking.clamp(requested_thinking(explicit, reasoning_effort, model), model)
end

function M.set_thinking_level(level, model_spec)
  local normalized = thinking.normalize(level)
  if not normalized then
    return false, "invalid thinking level"
  end
  local model = M.model_descriptor(model_spec)
  local effective = thinking.clamp(normalized, model)
  override_reasoning_effort = effective == "off" and "none" or effective
  session.append_thinking_level_change(effective)
  session.save()
  return true, effective
end

M.queue_steering = control.queue_steering
M.queue_follow_up = control.queue_follow_up
M.drain_steering = control.drain_steering
M.drain_follow_ups = control.drain_follow_ups
M.pending_message_count = control.pending_count
M.clear_queues = control.clear_queues

-- Append the user's turn, build the system prompt, and drive the
-- streaming tool loop via the chosen provider's run_turn.
--
-- The turn body always runs inside a sched coroutine so provider
-- code can freely yield at cooperative points (sched.http_poll,
-- sched.proc_poll) without the caller having to know. Non-TUI
-- modes get a trivial driver (no tick hook); the TUI installs its
-- own tick hook so its main loop keeps redrawing.
function M.run_turn(opts)
  local user_text = opts.user_text or ""
  session.append_user(user_text)
  session.save()

  local provider, resolved = pick_provider(M.current_model(opts.model))
  local thinking_level = M.thinking_level_for(resolved, opts.thinking_level, opts.reasoning_effort)
  local system_prompt = prompt.system_prompt()
  return sched.run(function()
    return provider.run_turn({
      system_prompt = system_prompt,
      model = resolved.id,
      max_tokens = opts.max_tokens,
      thinking_level = thinking_level,
      reasoning_effort = M.current_reasoning_effort(opts.reasoning_effort),
      observer = opts.observer,
      abort_check = opts.abort_check,
    })
  end)
end

-- Summarize the older half of the session using a one-shot completion
-- and rewrite the transcript in place. Returns (ok, summary_text).
function M.run_compact(opts)
  local keep_recent = opts.keep_recent or 12
  local message_count = psi.session_message_count()
  if message_count <= keep_recent + 1 then
    return true, "session is already small enough"
  end

  local provider, resolved = pick_provider(M.current_model(opts.model))
  local thinking_level = M.thinking_level_for(resolved, opts.thinking_level, opts.reasoning_effort)
  local request = prompt.compaction_request(keep_recent)
  local ok, summary = provider.complete_text({
    system_prompt = request[1],
    user_text = request[2],
    model = resolved.id,
    max_tokens = context.compaction_budget(),
    thinking_level = thinking_level,
    reasoning_effort = M.current_reasoning_effort(opts.reasoning_effort),
  })
  if not ok then
    return false
  end

  session.do_compact(keep_recent, summary)
  return true, summary
end

return M
