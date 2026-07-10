--[==[psi-test
expect = "pi-light"
env = { COLORFGBG = "0;15" }
]==]
-- A light terminal background (COLORFGBG ends in a high-luminance
-- index such as 15) must auto-select pi-light, mirroring pi's
-- detectTerminalBackgroundFromEnv.
local theme = require("psi.theme")
theme.bootstrap()
return theme.current_name()
