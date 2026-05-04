--[[psi-test
# Original: parts[0] > 100, parts[1] > 10, parts[2] == "nil". Folded.
expect = "true|true|true"
]]
local src = psi.embedded_source("psi.render")
local names = psi.embedded_source_names()
local missing = tostring(psi.embedded_source("no.such.module"))
return tostring((src and #src or 0) > 100) .. "|"
  .. tostring(#names > 10) .. "|"
  .. tostring(missing == "nil")
