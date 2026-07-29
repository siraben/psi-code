--[==[psi-test
expect = "false|4096|12345"
]==]
local settings = require("psi.settings_manager")
local values = {
  ["compaction.enabled"] = false,
  ["compaction.reserveTokens"] = 4096,
  ["compaction.keepRecentTokens"] = 12345,
}
settings.get = function(path, default)
  local value = values[path]
  if value == nil then
    return default
  end
  return value
end
local context = require("psi.context")
return table.concat({
  tostring(context.auto_compact_enabled()),
  tostring(context.reserve_tokens()),
  tostring(context.keep_recent_tokens()),
}, "|")
