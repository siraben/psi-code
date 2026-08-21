--[==[psi-test
expect = "complete|edited|1|1|true|failed|original|launch failed|1|1|failed|original|external editor exited with status 7|1|1|failed|original|failed to read editor temp file|1|1|failed|original|failed to write editor temp file|1|0|complete||1"
]==]
local rt = require("psi.tui_runtime")

local success = rt._debug_external_editor_transaction("success", "original")
local launch_failure = rt._debug_external_editor_transaction("launch-failure", "original")
local nonzero = rt._debug_external_editor_transaction("nonzero", "original")
local read_failure = rt._debug_external_editor_transaction("read-failure", "original")
local write_failure = rt._debug_external_editor_transaction("write-failure", "original")
local empty = rt._debug_external_editor_transaction("success", "original", "")

return table.concat({
  success.status,
  success.content,
  success.removed,
  success.launches,
  tostring(success.reanchor),
  launch_failure.status,
  launch_failure.content,
  launch_failure.message,
  launch_failure.removed,
  launch_failure.launches,
  nonzero.status,
  nonzero.content,
  nonzero.message,
  nonzero.removed,
  nonzero.launches,
  read_failure.status,
  read_failure.content,
  read_failure.message,
  read_failure.removed,
  read_failure.launches,
  write_failure.status,
  write_failure.content,
  write_failure.message,
  write_failure.removed,
  write_failure.launches,
  empty.status,
  empty.content,
  empty.removed,
}, "|")
