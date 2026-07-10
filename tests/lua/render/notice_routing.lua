--[==[psi-test
expect = "info:hello|error:boom|nosink"
]==]
-- notice.emit must emit the "notice" event when subscribed and fall
-- back to io.stderr only when unsubscribed.
local notice = require("psi.notice")

local seen = {}
psi.events.on("notice", function(payload)
  seen[#seen + 1] = tostring(payload.level) .. ":" .. tostring(payload.text)
end)

notice.info("hello")
notice.error("boom")

-- With the subscriber removed, notice must NOT emit a further event.
psi.events.off("notice", nil) -- no-op guard; explicit removal below
local handlers = psi.events.handlers("notice")
for _, fn in ipairs(handlers) do
  psi.events.off("notice", fn)
end
local before = #seen
notice.info("dropped-from-event") -- goes to stderr fallback, not the bus
local no_sink = (#seen == before) and "nosink" or "leaked"

return table.concat(seen, "|") .. "|" .. no_sink
