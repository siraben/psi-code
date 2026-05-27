--[==[psi-test
expect = "C:\\Users\\siraben\\Desktop\\note.txt|/C/Users/siraben/Desktop/note.txt"
env = { OS = "Windows_NT", TERM = "" }
]==]
local path_util = require("psi.path_utils")
return path_util.to_host("/C/Users/siraben/Desktop/note.txt")
  .. "|"
  .. path_util.from_host("C:\\Users\\siraben\\Desktop\\note.txt")
