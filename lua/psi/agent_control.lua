-- psi.agent_control: run-loop queues and control helpers.
--
-- Pi-mono keeps two message queues alongside the active run:
-- steering messages are injected before the next assistant response,
-- while follow-up messages are injected only after the agent would
-- otherwise stop. Psi stores transcript state in psi.session, so
-- draining a queue appends user messages directly to the session.

local session = require("psi.session_manager")

local M = {}

local steering_queue = {}
local follow_up_queue = {}
local next_queue_id = 0

local function copy_images(images)
  local out = {}
  if type(images) ~= "table" then
    return out
  end
  for i, image in ipairs(images) do
    if type(image) == "table" then
      out[i] = image
    end
  end
  return out
end

local function normalize_message(message)
  if type(message) == "string" then
    return message, {}
  end
  if type(message) == "table" then
    if type(message.text) == "string" then
      return message.text, copy_images(message.images)
    end
    if type(message.content) == "string" then
      return message.content, copy_images(message.images)
    end
  end
  return nil, nil
end

local function make_item(kind, message)
  local text, images = normalize_message(message)
  if text == nil then
    return nil
  end
  next_queue_id = next_queue_id + 1
  return {
    id = "q" .. tostring(next_queue_id),
    kind = kind,
    text = text,
    images = images or {},
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

local function drain_items(queue_name)
  local out
  if queue_name == "steering" then
    out = steering_queue
    steering_queue = {}
  else
    out = follow_up_queue
    follow_up_queue = {}
  end
  local items = {}
  for i, item in ipairs(out) do
    items[i] = {
      id = item.id,
      kind = item.kind,
      text = item.text,
      images = copy_images(item.images),
      timestamp = item.timestamp,
      index = i,
    }
  end
  return items
end

local function drain_texts(queue_name)
  local items = drain_items(queue_name)
  local texts = {}
  for i, item in ipairs(items) do
    texts[i] = item.text
  end
  return texts
end

local function append_drained(items, on_append, kind)
  for _, item in ipairs(items) do
    local text = item.text or ""
    local images = item.images or {}
    if #images > 0 and type(session.append_user_blocks) == "function" then
      session.append_user_blocks(text, images)
    else
      session.append_user(text)
    end
    if type(on_append) == "function" then
      on_append(text, kind, images)
    end
  end
  if #items > 0 then
    session.save()
  end
  return #items
end

local function copy_item(item, index)
  return {
    id = item.id,
    kind = item.kind,
    text = item.text,
    images = copy_images(item.images),
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

function M.drain_steering()
  return drain_texts("steering")
end

function M.drain_follow_ups()
  return drain_texts("follow_up")
end

function M.append_steering(on_append)
  return append_drained(drain_items("steering"), on_append, "steering")
end

function M.append_follow_ups(on_append)
  return append_drained(drain_items("follow_up"), on_append, "follow-up")
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
  local text, images = normalize_message(message)
  if text == nil then
    return false
  end
  item.text = text
  item.images = images or {}
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

return M
