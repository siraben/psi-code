--[==[psi-test
expect = "nil"
cwd = "trust-gated-ext"
files = [
  { path = ".psi/extensions/marker.lua", text = "psi._trust_test_marker = 'loaded'\n" },
]
]==]
-- Project-local extensions must not run when the project is untrusted.
return tostring(psi._trust_test_marker)
