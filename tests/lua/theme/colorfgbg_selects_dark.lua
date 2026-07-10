--[==[psi-test
expect = "pi-dark"
env = { COLORFGBG = "15;0" }
]==]
-- A dark terminal background (COLORFGBG ends in a low-luminance index
-- such as 0) keeps the default pi-dark theme.
local theme = require("psi.theme")
theme.bootstrap()
return theme.current_name()
