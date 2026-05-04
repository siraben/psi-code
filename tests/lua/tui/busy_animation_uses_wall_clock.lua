--[==[psi-test
expect = "0:0|0:0|1:1|1:1|2:2"
]==]
return require("psi.tui_runtime")._debug_busy_animation_frames({0, 599, 600, 1199, 1200})
