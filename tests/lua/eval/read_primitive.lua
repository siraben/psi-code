--[==[psi-test
expect = "ok"
]==]
return #psi.read_file("README.md") > 0 and "ok" or "bad"
