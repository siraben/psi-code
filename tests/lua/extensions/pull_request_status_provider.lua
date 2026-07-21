--[==[psi-test
expect = "github|forgejo|1|false|true|true|pr:#111|1|0|true"
]==]
local extension = require("psi.extensions.pull_request_status")
local github = extension._parse_remote("git@github.com:owner/repo.git")
local forgejo = extension._parse_remote("http://127.0.0.1:3010/owner/repo.git")
local begins = 0
local polls = 0
local timeout = nil
local argv = nil
local provider = extension.new_provider({
  cwd = function()
    return "/repo"
  end,
  branch = function()
    return "feature/metadata"
  end,
  remote = function()
    return { url = "http://127.0.0.1:3010/owner/repo.git" }
  end,
  begin = function(value)
    begins = begins + 1
    argv = value
    return {}
  end,
  poll = function(_, value)
    polls = polls + 1
    timeout = value
    return nil, polls > 1
  end,
  finish = function()
    return {
      status = 0,
      output = psi.json_encode({
        { number = 9, head = { ref = "other", repo = { full_name = "owner/repo" } } },
        { number = 111, head = { ref = "feature/metadata", repo = { full_name = "owner/repo" } } },
      }),
    }
  end,
  decode = psi.json_decode,
})
local changed_a, pending_a = provider.poll()
local changed, pending_b = provider.poll()
provider.poll()
return table.concat({
  github.kind,
  forgejo.kind,
  tostring(begins),
  tostring(changed_a),
  tostring(pending_a),
  tostring(changed and not pending_b),
  provider.text(),
  tostring(begins),
  tostring(timeout),
  tostring(argv[#argv]:find("/api/v1/repos/owner/repo/pulls", 1, true) ~= nil),
}, "|")
