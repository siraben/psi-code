--[[psi-test
# Folded checks: ok == "true", encoded length <= 184, encoded segment in path.
expect = "true|true|true"
cwd = "long-cwd/segment-00/segment-01/segment-02/segment-03/segment-04/segment-05/segment-06/segment-07/segment-08/segment-09/segment-10/segment-11/segment-12/segment-13/segment-14/segment-15/segment-16/segment-17/segment-18/segment-19/segment-20/segment-21/segment-22/segment-23/segment-24/segment-25/segment-26/segment-27/segment-28/segment-29/segment-30/segment-31/segment-32/segment-33/segment-34/segment-35"
env = { XDG_STATE_HOME = "{TMP}/state-long-cwd" }
]]
local s = require("psi.session_manager")
local path = s.ensure_default_path()
s.append_user("long path save")
local ok, err = s.save()
local encoded = s.encode_session_dir(psi.cwd())
return tostring(ok) .. "|"
  .. tostring(#encoded <= 184) .. "|"
  .. tostring(path:find("/" .. encoded .. "/", 1, true) ~= nil)
