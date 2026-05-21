--[==[psi-test
# list_all_sessions walks every cwd-encoded subdir under sessions_root
# and returns sessions regardless of which cwd they were recorded in.
# Used by the --resume picker when the user toggles to "all" scope.
expect = "true"
env = { XDG_STATE_HOME = "{TMP}/state" }
]==]
local s = require("psi.session_manager")

-- Fabricate two sessions in two different cwd buckets under
-- $STATE/psi/sessions, then check list_all_sessions sees both while
-- list_sessions(cwd_a) only sees the one rooted at cwd_a.
local root = s.sessions_root()
assert(root, "sessions_root() returned nil")

local function mkfile(path, payload)
  assert(psi.mkdir_parent(path), "mkdir_parent failed for " .. path)
  local f = assert(io.open(path, "w"))
  f:write(payload)
  f:close()
end

local cwd_a = TMP .. "/proj-a"
local cwd_b = TMP .. "/proj-b"

local dir_a = s.session_dir_for_cwd(cwd_a)
local dir_b = s.session_dir_for_cwd(cwd_b)

local function header(id, cwd)
  return string.format(
    '{"type":"session","id":"%s","cwd":"%s","timestamp":"2026-05-20T00:00:00Z"}\n',
    id, cwd
  )
end
local function msg(id, role, text)
  return string.format(
    '{"type":"message","id":"%s","timestamp":"2026-05-20T00:00:01Z",'
    .. '"message":{"role":"%s","content":[{"type":"text","text":"%s"}]}}\n',
    id, role, text
  )
end

mkfile(dir_a .. "/2026-05-20T00-00-00_aaaaaaaa.jsonl",
  header("aaaaaaaa", cwd_a) .. msg("m1", "user", "from proj-a"))
mkfile(dir_b .. "/2026-05-20T00-00-00_bbbbbbbb.jsonl",
  header("bbbbbbbb", cwd_b) .. msg("m2", "user", "from proj-b"))

local current = s.list_sessions(cwd_a)
local all = s.list_all_sessions()

local current_ok = #current == 1
  and current[1].id == "aaaaaaaa"
  and current[1].first_message:find("proj-a", 1, true) ~= nil

local seen_a, seen_b = false, false
for _, info in ipairs(all) do
  if info.id == "aaaaaaaa" then seen_a = true end
  if info.id == "bbbbbbbb" then seen_b = true end
end

return tostring(current_ok and seen_a and seen_b)
