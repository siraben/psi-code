--[[psi-test
contains = "1|ollama|3"
]]
local fired = 0
local seen_provider = ""
psi.events.on("context", function(p)
  fired = fired + 1
  seen_provider = p.provider or ""
  p.messages[#p.messages + 1] = "appended"
end)
local msgs = {"a", "b"}
psi.events.emit("context", {
  messages = msgs, provider = "ollama",
  model = "x", system_prompt = "s"
})
return fired .. "|" .. seen_provider .. "|" .. #msgs
