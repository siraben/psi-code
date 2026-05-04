--[==[psi-test
expect = "/tmp/x|x|/b|/|true"
]==]
return psi.path_join("/tmp/", "x") .. "|"
  .. psi.path_join(".", "x") .. "|"
  .. psi.path_join("/tmp/a", "/b") .. "|"
  .. psi.parent_directory("/usr/") .. "|"
  .. tostring(psi.path_expand("@~/psi-test"):match("/psi%-test$") ~= nil)
