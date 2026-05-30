-- psi.agent_control: run-loop queues and control helpers.
--
-- Pi-mono keeps two message queues alongside the active run:
-- steering messages are injected before the next assistant response,
-- while follow-up messages are injected only after the agent would
-- otherwise stop. Psi stores transcript state in psi.session, so
-- draining a queue appends user messages directly to the session.

local session = require("psi.session_manager")
local settings = require("psi.settings_manager")

local M = {}

local steering_queue = {}
local follow_up_queue = {}
local next_queue_id = 0
local queue_mode_overrides = {}

local function normalize_queue_name(name)
  name = tostring(name or ""):lower():gsub("_", "-")
  if name == "steer" or name == "steering" then
    return "steering"
  end
  if name == "follow" or name == "followup" or name == "follow-up" then
    return "follow-up"
  end
  return nil
end

local function normalize_queue_mode(mode)
  mode = tostring(mode or ""):lower():gsub("_", "-")
  if mode == "all" then
    return "all"
  end
  if mode == "one" or mode == "one-at-a-time" or mode == "one-at-time" then
    return "one-at-a-time"
  end
  return nil
end

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

local function make_item(kind, message)
  local text = normalize_text(message)
  if text == nil then
    return nil
  end
  next_queue_id = next_queue_id + 1
  return {
    id = "q" .. tostring(next_queue_id),
    kind = kind,
    text = text,
    timestamp = os.time(),
  }
end

local function push(kind, queue, message)
  local item = make_item(kind, message)
  if item == nil then
    return false
  end
  queue[#queue + 1] = item
  return true
end

local function queue_mode(queue_name)
  queue_name = normalize_queue_name(queue_name) or "follow-up"
  if queue_mode_overrides[queue_name] ~= nil then
    return queue_mode_overrides[queue_name]
  end
  local key = queue_name == "steering" and "steeringMode" or "followUpMode"
  local mode = settings.get(key, nil)
  if mode == nil then
    local nested = queue_name == "steering" and "queue.steeringMode" or "queue.followUpMode"
    mode = settings.get(nested, nil)
  end
  return mode == "all" and "all" or "one-at-a-time"
end

local function drain(queue_name)
  local queue
  if queue_name == "steering" then
    queue = steering_queue
  else
    queue = follow_up_queue
  end

  local count = #queue
  if count == 0 then
    return {}
  end
  if queue_mode(queue_name) ~= "all" then
    count = 1
  end

  local texts = {}
  for i = 1, count do
    local item = queue[i]
    texts[i] = item.text
  end
  for _ = 1, count do
    table.remove(queue, 1)
  end
  return texts
end

local function append_drained(messages, on_append, kind)
  for _, text in ipairs(messages) do
    session.append_user(text)
    if type(on_append) == "function" then
      on_append(text, kind)
    end
  end
  if #messages > 0 then
    session.save()
  end
  return #messages
end

local function copy_item(item, index)
  return {
    id = item.id,
    kind = item.kind,
    text = item.text,
    timestamp = item.timestamp,
    index = index,
  }
end

local function pending_ref(index)
  index = tonumber(index)
  if not index or index < 1 then
    return nil
  end
  if index <= #steering_queue then
    return steering_queue, index, steering_queue[index], index
  end
  local follow_index = index - #steering_queue
  if follow_index >= 1 and follow_index <= #follow_up_queue then
    return follow_up_queue, follow_index, follow_up_queue[follow_index], index
  end
  return nil
end

function M.queue_steering(message)
  return push("steering", steering_queue, message)
end

function M.queue_follow_up(message)
  return push("follow-up", follow_up_queue, message)
end

function M.queue_mode(kind)
  local normalized = normalize_queue_name(kind)
  if normalized == nil then
    return nil
  end
  return queue_mode(normalized)
end

function M.queue_modes()
  return {
    steering = queue_mode("steering"),
    ["follow-up"] = queue_mode("follow-up"),
  }
end

function M.set_queue_mode(kind, mode)
  local normalized_kind = normalize_queue_name(kind)
  local normalized_mode = normalize_queue_mode(mode)
  if normalized_kind == nil then
    return false, "queue kind must be steering or follow-up"
  end
  if normalized_mode == nil then
    return false, "queue mode must be one-at-a-time or all"
  end
  queue_mode_overrides[normalized_kind] = normalized_mode
  return true, normalized_kind, normalized_mode
end

function M.drain_steering()
  return drain("steering")
end

function M.drain_follow_ups()
  return drain("follow_up")
end

function M.append_steering(on_append)
  return append_drained(M.drain_steering(), on_append, "steering")
end

function M.append_follow_ups(on_append)
  return append_drained(M.drain_follow_ups(), on_append, "follow-up")
end

function M.pending_count()
  return #steering_queue + #follow_up_queue
end

function M.pending_messages()
  local out = {}
  local n = 0
  for _, item in ipairs(steering_queue) do
    n = n + 1
    out[n] = copy_item(item, n)
  end
  for _, item in ipairs(follow_up_queue) do
    n = n + 1
    out[n] = copy_item(item, n)
  end
  return out
end

function M.pending_message(index)
  local _, _, item, global_index = pending_ref(index)
  if item == nil then
    return nil
  end
  return copy_item(item, global_index)
end

function M.replace_pending(index, message)
  local _, _, item = pending_ref(index)
  if item == nil then
    return false
  end
  local text = normalize_text(message)
  if text == nil then
    return false
  end
  item.text = text
  return true
end

function M.remove_pending(index)
  local queue, local_index = pending_ref(index)
  if queue == nil then
    return nil
  end
  local removed = table.remove(queue, local_index)
  return removed and removed.text or nil
end

function M.clear_queues()
  steering_queue = {}
  follow_up_queue = {}
end

function M.clear_queue(kind)
  local normalized = normalize_queue_name(kind)
  if normalized == "steering" then
    local n = #steering_queue
    steering_queue = {}
    return n
  end
  if normalized == "follow-up" then
    local n = #follow_up_queue
    follow_up_queue = {}
    return n
  end
  return nil
end

return M
