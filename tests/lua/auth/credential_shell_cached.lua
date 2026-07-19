--[==[psi-test
expect = "tok-1|tok-1|literal-value"
env = { PSI_CRED_COUNTER_FILE = "{TMP}/counter" }
]==]
-- A `!shell-command` credential runs once and is cached per process:
-- the command appends to a file each run, so a second resolve of the
-- same command must NOT increment it (still "tok-1"). A plain literal
-- passes through untouched.
local credential = require("psi.credential")
credential._reset_cache()
local counter = os.getenv("PSI_CRED_COUNTER_FILE")
-- Each invocation appends an "x" and prints the current byte count.
local cmd = "!printf x >> " .. counter .. "; printf 'tok-'; wc -c < " .. counter .. " | tr -d ' \\n'"
local first = credential.resolve(cmd)
local second = credential.resolve(cmd)
local literal = credential.resolve("literal-value")
return table.concat({ tostring(first), tostring(second), tostring(literal) }, "|")
