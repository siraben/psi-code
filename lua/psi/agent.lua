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
local anthropic = require("psi.anthropic")
local ollama = require("psi.ollama")

local M = {}

-- ---------- Provider routing ----------
--
-- Selection rules, in priority:
--   1. Explicit model prefix: "ollama/<name>" or "anthropic/<name>"
--      strips the prefix and routes accordingly.
--   2. $PSI_PROVIDER env ("ollama" | "anthropic").
--   3. Default: anthropic.
local function pick_provider(model)
  if type(model) == "string" then
    local after = model:match("^ollama/(.+)$")
    if after then return ollama, after end
    after = model:match("^anthropic/(.+)$")
    if after then return anthropic, after end
  end
  local env = os.getenv("PSI_PROVIDER")
  if env == "ollama" then return ollama, model end
  return anthropic, model
end

function M.provider_for(model) return pick_provider(model) end

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

  local provider, real_model = pick_provider(opts.model)
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

  local provider, real_model = pick_provider(opts.model)
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
