--[==[psi-test
expect = "info:hello|error:boom|nosink"
]==]
-- notice.emit routes through the "notice" event when a subscriber is
-- registered (the TUI case), and only falls back to io.stderr when no
-- subscriber exists (headless). This is what keeps auto-compaction and
-- auth-failure messages out of the raw terminal while the TUI paints.
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
