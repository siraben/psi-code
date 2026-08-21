--[==[psi-test
cwd = "proj"
files = [
  { path = "src/main.c", text = "int main(void){return 0;}" },
  { path = "src/util.c", text = "" },
]
expect = "src/main.c|src/util.c"
]==]
local c = require("psi.slash_commands")
local r = c.input_completions("src/", 4, 24, false)
local out = {}
for _, it in ipairs(r.items) do
  out[#out + 1] = it.insert
end
return table.concat(out, "|") .. (r.kind == "path" and "" or "|wrong-kind")
