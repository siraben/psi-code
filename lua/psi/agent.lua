-- psi.agent: high-level turn/compact orchestrators.
--
-- These live in Lua so the C layer is left with only VM lifecycle +
-- HTTP primitives. C calls run_turn / run_compact via the
-- psi_vm_run_agent_* bridge helpers; everything downstream (session ↔
-- API message mapping, tool loop, compaction assembly) is pure Lua.

local context = require("psi.context")
local prompt = require("psi.prompt")
local session = require("psi.session")
local anthropic = require("psi.anthropic")

local M = {}

-- Append the user's turn, build the system prompt, and drive the
-- streaming tool loop via psi.anthropic.run_turn.
function M.run_turn(opts)
  local user_text = opts.user_text or ""
  session.append_user(user_text)
  session.save()

  local system_prompt = prompt.system_prompt()
  return anthropic.run_turn({
    system_prompt = system_prompt,
    model = opts.model,
    max_tokens = opts.max_tokens,
    observer = opts.observer,
    abort_check = opts.abort_check,
  })
end

-- Summarize the older half of the session using a one-shot completion
-- and rewrite the transcript in place. Returns (ok, summary_text).
function M.run_compact(opts)
  local keep_recent = opts.keep_recent or 12
  local message_count = psi.session_message_count()
  if message_count <= keep_recent + 1 then
    return true, "session is already small enough"
  end

  local request = prompt.compaction_request(keep_recent)
  local ok, summary = anthropic.complete_text({
    system_prompt = request[1],
    user_text = request[2],
    model = opts.model,
    max_tokens = context.compaction_budget(),
  })
  if not ok then return false end

  session.do_compact(keep_recent, summary)
  return true, summary
end

return M
