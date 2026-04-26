-- psi.agent: high-level turn/compact orchestrators.
--
-- These live in Lua so the C layer is left with only VM lifecycle +
-- HTTP primitives. C calls run_turn / run_compact via the
-- psi_vm_run_agent_* bridge helpers; everything downstream (session ↔
-- API message mapping, tool loop, compaction assembly) is pure Lua.

local context = require("psi.context")
local prompt = require("psi.prompt")
local sched = require("psi.sched")
local session = require("psi.session")
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
  local spec, real_model = providers.resolve_route(model)
  return providers.load_provider(spec), providers.resolve_model(spec.name, real_model)
end

function M.provider_for(model)
  return pick_provider(model)
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

  local provider, real_model = pick_provider(M.current_model(opts.model))
  local system_prompt = prompt.system_prompt()
  return sched.run(function()
    return provider.run_turn({
      system_prompt = system_prompt,
      model = real_model,
      max_tokens = opts.max_tokens,
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

  local provider, real_model = pick_provider(M.current_model(opts.model))
  local request = prompt.compaction_request(keep_recent)
  local ok, summary = provider.complete_text({
    system_prompt = request[1],
    user_text = request[2],
    model = real_model,
    max_tokens = context.compaction_budget(),
  })
  if not ok then
    return false
  end

  session.do_compact(keep_recent, summary)
  return true, summary
end

return M
