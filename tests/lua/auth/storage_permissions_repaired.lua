--[==[psi-test
expect = "384"
env = { PSI_AUTH_FILE = "{TMP}/auth.json" }
]==]
-- A loose auth.json is tightened to 0600 on read, like ssh key files.
local path = os.getenv("PSI_AUTH_FILE")
assert(psi.file_write(path, "{}"))
assert(psi.file_chmod(path, 420))
local auth = require("psi.auth_storage")
auth.load()
return tostring(psi.file_mode(path))
