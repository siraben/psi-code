--[==[psi-test
expect = "true|true|true"
cwd = "project"
env = { PSI_NETWORK_SEARCH_ENABLED = "1", PSI_NETWORK_SEARCH_API_KEY = "secret" }

[[files]]
path = ".psi/settings.json"
json = { extensions = { network_search = { provider = "generic", endpoint = "https://search.test/", max_response_bytes = 1024 } } }
]==]
local chunks = { string.rep("x", 1025) }
local index = 0
local finishes = 0
psi.http_stream_begin = function()
  return {}
end
psi.http_stream_poll = function()
  index = index + 1
  return chunks[index], true
end
psi.http_stream_finish = function()
  finishes = finishes + 1
  return 200
end

local oversized = psi.sched.run(function()
  return psi.tools.dispatch("network_search", { query = "q", count = 1 })
end)

local aborted = false
psi.is_aborted = function()
  return aborted
end
psi.http_stream_poll = function()
  aborted = true
  return nil, false
end
local abort_result = psi.sched.run(function()
  return psi.tools.dispatch("network_search", { query = "q", count = 1 })
end)
return table.concat({
  tostring(oversized.error:find("byte limit", 1, true) ~= nil),
  tostring(abort_result.error:find("aborted", 1, true) ~= nil),
  tostring(finishes == 2),
}, "|")
