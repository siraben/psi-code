-- psi.thinking: pi-compatible thinking/reasoning level helpers.

local M = {}

M.DEFAULT = "medium"

local VALID = {
  off = true,
  minimal = true,
  low = true,
  medium = true,
  high = true,
  xhigh = true,
  max = true,
}

function M.is_valid(level)
  return type(level) == "string" and VALID[level] == true
end

function M.normalize(level)
  if level == nil or level == "" then
    return nil
  end
  level = tostring(level):lower()
  if M.is_valid(level) then
    return level
  end
  return nil
end

function M.supports_thinking(model)
  return type(model) == "table" and model.reasoning == true
end

function M.supports_xhigh(model)
  if type(model) ~= "table" then
    return false
  end
  local id = tostring(model.id or model.model or "")
  return id:find("gpt%-5%.2", 1, false) ~= nil
    or id:find("gpt%-5%.3", 1, false) ~= nil
    or id:find("gpt%-5%.4", 1, false) ~= nil
    or id:find("gpt%-5%.5", 1, false) ~= nil
    or id:find("gpt%-5%.6", 1, false) ~= nil
    or id:find("deepseek%-v4%-pro", 1, false) ~= nil
    or id:find("opus%-4%-6", 1, false) ~= nil
    or id:find("opus%-4%.6", 1, false) ~= nil
    or id:find("opus%-4%-7", 1, false) ~= nil
    or id:find("opus%-4%.7", 1, false) ~= nil
end

function M.available(model)
  if not M.supports_thinking(model) then
    return { "off" }
  end
  if M.supports_xhigh(model) then
    return { "off", "minimal", "low", "medium", "high", "xhigh", "max" }
  end
  return { "off", "minimal", "low", "medium", "high" }
end

function M.clamp(level, model)
  level = M.normalize(level) or M.DEFAULT
  if not M.supports_thinking(model) then
    return "off"
  end
  if (level == "xhigh" or level == "max") and not M.supports_xhigh(model) then
    return "high"
  end
  return level
end

function M.request_effort(level, model)
  level = M.clamp(level, model)
  if level == "off" then
    return nil
  end

  local id = tostring((type(model) == "table" and (model.id or model.model)) or model or "")
  if
    level == "minimal"
    and (
      id:find("gpt%-5%.2", 1, false) ~= nil
      or id:find("gpt%-5%.3", 1, false) ~= nil
      or id:find("gpt%-5%.4", 1, false) ~= nil
      or id:find("gpt%-5%.5", 1, false) ~= nil
      or id:find("gpt%-5%.6", 1, false) ~= nil
    )
  then
    return "low"
  end
  if id == "gpt-5.1" and level == "xhigh" then
    return "high"
  end
  if id == "gpt-5.1-codex-mini" then
    if level == "high" or level == "xhigh" or level == "max" then
      return "high"
    end
    return "medium"
  end
  return level
end

return M
