--[==[psi-test
expect = "loaded"
cwd = "trust-env-ext"
env = { PSI_TRUST = "always" }
files = [
  { path = ".psi/extensions/marker.lua", text = "psi._trust_test_marker = 'loaded'\n" },
]
]==]
return tostring(psi._trust_test_marker)
