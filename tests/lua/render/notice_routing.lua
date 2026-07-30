--[==[psi-test
expect = "info:hello|error:boom|stale-safe|nosink"
]==]
-- The terminal-owning frontend uses an explicit sink rather than an event
-- subscriber, so /reload cannot silently detach it.
local notice = require("psi.notice")

local seen = {}
local token = notice.set_sink(function(payload)
  seen[#seen + 1] = tostring(payload.level) .. ":" .. tostring(payload.text)
end)

notice.info("hello")
notice.error("boom")

psi.events.clear()
notice.clear_sink(token)
local before = #seen
notice.info("dropped-from-sink") -- goes to stderr fallback
local no_sink = (#seen == before) and "nosink" or "leaked"

local old = notice.set_sink(function() end)
local current = notice.set_sink(function(payload)
  seen[#seen + 1] = payload.text
end)
notice.clear_sink(old)
notice.info("stale-safe")
notice.clear_sink(current)

return table.concat(seen, "|") .. "|" .. no_sink
