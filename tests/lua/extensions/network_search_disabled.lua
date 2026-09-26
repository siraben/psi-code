--[==[psi-test
expect = "true|true"
]==]
local source = psi.embedded_source("psi.extensions.network_search")
return table.concat({
  tostring(psi.tools.find("network_search") == nil),
  tostring(type(source) == "string" and source:find("Optional network-search", 1, true) ~= nil),
}, "|")
