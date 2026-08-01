-- psi.agent: high-level turn/compact orchestrators.
--
-- These live in Lua so the C layer is left with only VM lifecycle +
-- HTTP primitives. C calls run_turn / run_compact via the
-- psi_vm_run_agent_* bridge helpers; everything downstream (session ↔
-- API message mapping, tool loop, compaction assembly) is pure Lua.

local context = require("psi.context")
local control = require("psi.agent_control")
local transform = require("psi.transform_messages")
local prompt = require("psi.prompt")
local sched = require("psi.sched")
local session = require("psi.session_manager")
local thinking = require("psi.thinking")
local providers = require("psi.api_registry")

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
local configured_model = nil

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

function M.configure(opts)
  opts = opts or {}
  configured_model = opts.model
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
  if fallback ~= nil and fallback ~= "" then
    return fallback
  end
  if configured_model ~= nil and configured_model ~= "" then
    return configured_model
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
M.queue_internal_follow_up = control.queue_internal_follow_up
M.clear_internal_follow_ups = control.clear_internal_follow_ups
M.queue_mode = control.queue_mode
M.queue_modes = control.queue_modes
M.set_queue_mode = control.set_queue_mode
M.drain_steering = control.drain_steering
M.drain_follow_ups = control.drain_follow_ups
M.pending_message_count = control.pending_count
M.pending_messages = control.pending_messages
M.pending_message = control.pending_message
M.replace_pending = control.replace_pending
M.remove_pending = control.remove_pending
M.clear_queues = control.clear_queues
M.clear_queue = control.clear_queue

local function transcript_excerpt(max_chars)
  max_chars = tonumber(max_chars) or 24000
  local entries = {}
  for _, m in ipairs(transform.plain_session()) do
    local role = m.role or "message"
    local text = m.text or ""
    if text ~= "" then
      entries[#entries + 1] = role .. ":\n" .. text
    end
  end
  local out = table.concat(entries, "\n\n")
  if #out <= max_chars then
    return out
  end
  return out:sub(#out - max_chars + 1)
end

local SIDE_QUESTION_SYSTEM = table.concat({
  "You are answering an ephemeral /btw side question inside psi. ",
  "The caller will provide a bounded transcript excerpt and a side question. ",
  "Answer concisely from that excerpt. ",
  "If the excerpt is empty or insufficient, say that plainly. ",
  "You cannot call tools in this mode. ",
  "Do not ask to run tools, do not modify files, and do not add anything to the main transcript.",
})

-- Append the user's turn, build the system prompt, and drive the
-- streaming tool loop via the chosen provider's run_turn.
--
-- The turn body always runs inside a sched coroutine so provider
-- code can freely yield at cooperative points (sched.http_poll,
-- sched.proc_poll) without the caller having to know. Non-TUI
-- modes get a trivial driver (no tick hook); the TUI installs its
-- own tick hook so its main loop keeps redrawing.
local function turn_max_tokens(resolved, requested)
  local requested_tokens = tonumber(requested)
  if requested_tokens and requested_tokens > 0 then
    return math.floor(requested_tokens)
  end
  local model_tokens = tonumber(resolved and resolved.max_output_tokens)
  if model_tokens and model_tokens > 0 then
    return math.floor(model_tokens)
  end
  return nil
end

local function drive_turn(opts, append_user)
  if append_user then
    local user_text = opts.user_text or ""
    session.append_user(user_text)
    session.save()
  end
  local provider, resolved = pick_provider(M.current_model(opts.model))
  local thinking_level = M.thinking_level_for(resolved, opts.thinking_level, opts.reasoning_effort)
  local system_prompt = prompt.system_prompt()
  return sched.run(function()
    return provider.run_turn({
      system_prompt = system_prompt,
      model = resolved.id,
      max_tokens = turn_max_tokens(resolved, opts.max_tokens),
      thinking_level = thinking_level,
      reasoning_effort = M.current_reasoning_effort(opts.reasoning_effort),
      observer = opts.observer,
      abort_check = opts.abort_check,
    })
  end)
end

function M.run_turn(opts)
  return drive_turn(opts, true)
end

function M.continue_turn(opts)
  return drive_turn(opts or {}, false)
end

function M.side_question(question, opts)
  opts = opts or {}
  if type(question) ~= "string" or question == "" then
    return false, "missing question"
  end

  local excerpt = transcript_excerpt(opts.context_chars or 24000)
  local excerpt_text = excerpt ~= "" and excerpt or "(empty transcript)"

  local provider, resolved = pick_provider(M.current_model(opts.model))
  local user_text = "Current transcript excerpt:\n\n"
    .. excerpt_text
    .. "\n\nSide question:\n"
    .. question

  local function complete()
    return provider.complete_text({
      system_prompt = SIDE_QUESTION_SYSTEM,
      user_text = user_text,
      model = resolved.id,
      max_tokens = opts.max_tokens or 1024,
      thinking_level = M.thinking_level_for(resolved, opts.thinking_level, opts.reasoning_effort),
      reasoning_effort = M.current_reasoning_effort(opts.reasoning_effort),
      abort_check = opts.abort_check,
    })
  end

  if sched.in_coroutine and sched.in_coroutine() then
    return complete()
  end
  return sched.run(complete)
end

-- Summarize the older half of the session using a one-shot completion
-- and rewrite the transcript in place. Returns (ok, summary_text).
function M.run_compact(opts)
  opts = opts or {}
  local plan = opts.plan
  if not plan then
    if opts.keep_recent ~= nil then
      plan = session.prepare_compaction({ keep_recent_messages = opts.keep_recent })
    else
      plan = session.prepare_compaction({ keep_recent_tokens = context.keep_recent_tokens() })
    end
  end
  if not plan then
    return true, "session is already small enough"
  end
  plan.tokens_before = context.estimate_context_tokens().tokens
  plan.reason = opts.reason

  local provider, resolved = pick_provider(M.current_model(opts.model))
  local thinking_level = M.thinking_level_for(resolved, opts.thinking_level, opts.reasoning_effort)

  local function complete(request, max_tokens)
    local model_max = tonumber(resolved.max_output_tokens)
    if model_max and model_max > 0 then
      max_tokens = math.min(max_tokens, model_max)
    end
    return sched.run(function()
      return provider.complete_text({
        system_prompt = request[1],
        user_text = request[2],
        model = resolved.id,
        max_tokens = max_tokens,
        thinking_level = thinking_level,
        reasoning_effort = M.current_reasoning_effort(opts.reasoning_effort),
        abort_check = opts.abort_check,
      })
    end)
  end

  local summary
  if plan.is_split_turn then
    local history = plan.previous_summary or "No prior history."
    if #plan.messages_to_summarize > 0 then
      local ok
      ok, history = complete(prompt.compaction_request(plan), context.compaction_budget())
      if not ok then
        return false, history
      end
    end
    local ok, prefix = complete(prompt.turn_prefix_request(plan), context.turn_prefix_budget())
    if not ok then
      return false, prefix
    end
    summary = history .. "\n\n---\n\n**Turn Context (split turn):**\n\n" .. prefix
  else
    local request = prompt.compaction_request(plan)
    local ok
    ok, summary = complete(request, context.compaction_budget())
    if not ok then
      return false, summary
    end
  end

  summary = (summary or "") .. prompt.format_file_operations(plan.read_files, plan.modified_files)
  local compacted, err = session.do_compact(plan, summary)
  if not compacted then
    return false, err
  end
  context.reset_usage()
  return true, summary
end

function M.run_tree(opts)
  opts = opts or {}
  local target = opts.target
  if type(target) ~= "string" or target == "" then
    return false, "missing target entry id"
  end

  if not opts.summarize then
    local ok, result = session.branch(target)
    if not ok then
      return false, result
    end
    return true,
      {
        target = result,
        summary = nil,
        tree = session.branch_tree_text(),
      }
  end

  local entries, target_id, old_leaf, common = session.branch_entries_to_summarize(target)
  if not entries then
    return false, target_id
  end
  if old_leaf == target_id or #entries == 0 then
    local ok, result = session.branch(target_id)
    if not ok then
      return false, result
    end
    return true,
      {
        target = result,
        summary = nil,
        tree = session.branch_tree_text(),
      }
  end

  local provider, resolved = pick_provider(M.current_model(opts.model))
  local thinking_level = M.thinking_level_for(resolved, opts.thinking_level, opts.reasoning_effort)
  local request = prompt.branch_summary_request(entries, opts.custom_instructions)
  local ok, summary = sched.run(function()
    return provider.complete_text({
      system_prompt = request[1],
      user_text = request[2],
      model = resolved.id,
      max_tokens = opts.max_tokens or context.compaction_budget(),
      thinking_level = thinking_level,
      reasoning_effort = M.current_reasoning_effort(opts.reasoning_effort),
      abort_check = opts.abort_check,
    })
  end)
  if not ok then
    return false, summary
  end
  summary = (request[3] or "") .. (summary or "")
  local switched, summary_id = session.branch_with_summary(target_id, summary, {
    fromId = old_leaf,
    commonAncestorId = common,
  })
  if not switched then
    return false, summary_id
  end
  return true,
    {
      target = target_id,
      summary = summary,
      summary_id = summary_id,
      tree = session.branch_tree_text(),
    }
end

return M
