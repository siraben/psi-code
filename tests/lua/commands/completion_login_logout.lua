--[==[psi-test
expect = "true|true|true|true"
env = { PSI_AUTH_FILE = "{TMP}/auth.json" }
files = [
  { path = "{TMP}/auth.json", json = { anthropic = { type = "api_key", key = "secret" } } },
]
]==]
local commands = require("psi.slash_commands")
local first = commands.input_completions("/login ", 7, 24, false)
local nested = commands.input_completions("/login api-key an", 17, 24, false)
local logout = commands.input_completions("/logout an", 10, 24, false)
local function has(result, value)
  for _, item in ipairs(result and result.items or {}) do
    if item.insert == value then
      return true
    end
  end
  return false
end
return table.concat({
  tostring(has(first, "api-key")),
  tostring(has(first, "openai-codex")),
  tostring(has(nested, "anthropic") and nested.start == 16),
  tostring(has(logout, "anthropic")),
}, "|")
