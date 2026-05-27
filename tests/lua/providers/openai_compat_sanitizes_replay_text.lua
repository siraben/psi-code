--[==[psi-test
expect = "system|true|true|true|true|true"
]==]
local s = require("psi.session_manager")
local compat = require("psi.providers.openai_compat")

s.append_user("a\x88b")
s.append_assistant("c\x88d", {
  { type = "text", text = "c\x88d" },
  { type = "tool_use", id = "call_1", name = "bash", input = { command = "pwd" } },
}, {})
s.append_tool_result("call_1", "bash", "e\x88f", false)
s.append_compaction("g\x88h")
s.append_custom_message("i\x88j", { role = "assistant" })

local cfg = {
  tool_result_message = function(tool_call_id, _tool_name, text)
    return { role = "tool", tool_call_id = tool_call_id, content = text }
  end,
  assistant_tool_call = function(block)
    return {
      id = block.id,
      type = "function",
      ["function"] = {
        name = block.name,
        arguments = "{}",
      },
    }
  end,
}

local wire = compat.build_api_messages(s.messages(), "sys\x88tem", cfg)
local repl = "\239\191\189"
return table.concat({
  wire[1].content,
  tostring(wire[2].content == ("a" .. repl .. "b")),
  tostring(wire[3].content == ("c" .. repl .. "d")),
  tostring(wire[4].content == ("e" .. repl .. "f")),
  tostring(wire[5].content == ("g" .. repl .. "h")),
  tostring(wire[6].content == ("i" .. repl .. "j")),
}, "|")
