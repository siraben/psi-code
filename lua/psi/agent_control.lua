-- psi.agent_control: run-loop queues and control helpers.
--
-- Pi-mono keeps two message queues alongside the active run:
-- steering messages are injected before the next assistant response,
-- while follow-up messages are injected only after the agent would
-- otherwise stop. Psi stores transcript state in psi.session, so
-- draining a queue appends user messages directly to the session.

local session = require("psi.session")

local M = {}

local steering_queue = {}
local follow_up_queue = {}

local function normalize_text(message)
  if type(message) == "string" then
    return message
  end
  if type(message) == "table" then
    if type(message.text) == "string" then
      return message.text
    end
    if type(message.content) == "string" then
      return message.content
    end
  end
  return nil
end

local function push(queue, message)
  local text = normalize_text(message)
  if text == nil then
    return false
  end
  queue[#queue + 1] = text
  return true
end

local function drain(queue_name)
  local out
  if queue_name == "steering" then
    out = steering_queue
    steering_queue = {}
  else
    out = follow_up_queue
    follow_up_queue = {}
  end
  return out
end

local function append_drained(messages)
  for _, text in ipairs(messages) do
    session.append_user(text)
  end
  if #messages > 0 then
    session.save()
  end
  return #messages
end

function M.queue_steering(message)
  return push(steering_queue, message)
end

function M.queue_follow_up(message)
  return push(follow_up_queue, message)
end

function M.drain_steering()
  return drain("steering")
end

function M.drain_follow_ups()
  return drain("follow_up")
end

function M.append_steering()
  return append_drained(M.drain_steering())
end

function M.append_follow_ups()
  return append_drained(M.drain_follow_ups())
end

function M.pending_count()
  return #steering_queue + #follow_up_queue
end

function M.clear_queues()
  steering_queue = {}
  follow_up_queue = {}
end

return M
