--[==[psi-test
expect = "true|600"
]==]
local path = psi.tempfile_path("psi-test-")
local exists = type(path) == "string" and psi.file_type(path) == "file"
local stat = psi.process_run_argv({"stat", "-c", "%a", path or ""})
return tostring(exists) .. "|" .. (stat.output or ""):gsub("%s+$", "")
