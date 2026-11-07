-- psi.prompt: system prompt, compaction request, runtime summary, help text.

local prelude = require("psi.prelude")
local session = require("psi.session_manager")
local tools = require("psi.tools")
local resources = require("psi.resource_loader")
local platform = require("psi.platform")
local projection = require("psi.session_projection")

local M = {}

function M.find_context_files()
  return resources.context_files()
end

-- Structure ported from pi-mono (MIT, (c) 2025 Mario Zechner) with the
-- harness name changed to "psi". See
-- pi-mono/packages/coding-agent/src/core/system-prompt.ts.

local PREAMBLE = table.concat({
  "You are an expert coding assistant operating inside psi, a coding agent harness. ",
  "You help users by reading files, executing commands, editing code, and writing new files.",
})

local function escape_attr(value)
  value = tostring(value or "")
  value = value:gsub("&", "&amp;")
  value = value:gsub('"', "&quot;"):gsub("'", "&apos;")
  value = value:gsub("<", "&lt;"):gsub(">", "&gt;")
  return value
end

local BASE_GUIDELINES = {
  "Be concise in your responses",
  "Show file paths clearly when working with files",
}

local function tool_set(tool_list)
  local set = {}
  for _, t in ipairs(tool_list) do
    set[t.name] = true
  end
  return set
end

local function exploration_guideline(have)
  if have.bash and not have.grep and not have.find and not have.ls then
    if platform.is_windows() then
      return "Use bash for short inline Windows shell operations; it runs cmd.exe /d /c on this host"
    end
    return "Use bash for file operations like ls, rg, find"
  end
  if have.bash and (have.grep or have.find or have.ls) then
    return "Prefer grep/find/ls tools over bash for file exploration (faster, bounded, avoids common ignored directories)"
  end
  return nil
end

local function write_line(buf, prefix, line)
  buf[#buf + 1] = prefix .. line .. "\n"
end

-- System-prompt transformers. Each registered fn receives the
-- currently-assembled prompt string and returns a replacement string
-- (or nil / "" to leave the prompt unchanged). Runs in registration
-- order after the built-in assembly, so transformers stack.
--
-- Use this from an extension when you want to inject project-specific
-- guidance, swap a tone, or override parts of the prompt entirely.
-- For additive content, just concatenate; for replacement, return a
-- wholly different string.
local transformers = {}

function M.register_transformer(fn)
  transformers[#transformers + 1] = fn
end

function M.clear_transformers()
  transformers = {}
end

-- Ordered sections and wording follow Pi 1.4.0 system-prompt.ts and
-- skills.ts (MIT, Mario Zechner); branding/docs and executable tools are local.
function M.system_sections()
  local _, custom = resources.system_prompt_file()
  local _, addendum = resources.append_system_prompt_file()
  local all_tools = tools.active()
  local have, sections, order = tool_set(all_tools), {}, {}
  local function section(name, value)
    if value and value ~= "" then
      order[#order + 1] = name
      sections[name] = name == "preamble" and value
        or ("<" .. name .. ">\n" .. value .. "\n</" .. name .. ">")
    end
  end
  section("preamble", custom and custom ~= "" and custom or PREAMBLE)
  if not custom or custom == "" then
    local snippets, rules, seen = {}, {}, {}
    for _, tool in ipairs(all_tools) do
      if tool.prompt_snippet and tool.prompt_snippet ~= "" then
        snippets[#snippets + 1] = "- " .. tool.name .. ": " .. tool.prompt_snippet
      end
    end
    section(
      "tools",
      (#snippets > 0 and table.concat(snippets, "\n") or "(none)")
        .. "\n\nIn addition to the tools above, you may have access to other custom tools depending on the project."
    )
    local function rule(value)
      value = type(value) == "string" and value:match("^%s*(.-)%s*$") or nil
      if value and value ~= "" and not seen[value] then
        seen[value] = true
        write_line(rules, "- ", value)
      end
    end
    rule(exploration_guideline(have))
    for _, tool in ipairs(all_tools) do
      for _, value in ipairs(tool.guidelines or {}) do
        rule(value)
      end
    end
    for _, value in ipairs(BASE_GUIDELINES) do
      rule(value)
    end
    section("rules", (table.concat(rules):gsub("\n$", "")))
    section(
      "docs",
      table.concat({
        "Psi documentation (read only when the user asks about psi itself, its architecture, Lua modules, or host layer):",
        "- README.md — main documentation",
        "- docs/architecture.md — architecture overview",
        "- docs/port-status.md — port audit against pi",
        "- docs/extensions.md — extension / event / slash-command API",
        "- docs/providers.md — provider routing and configuration",
        "- These paths serve embedded documentation when the file is not on disk.",
        "- Always read the target .md file completely and follow links to related docs.",
      }, "\n")
    )
  end
  section("addendum", addendum)
  local context_files = M.find_context_files()
  if #context_files > 0 then
    local lines = { "Project-specific instructions and guidelines:" }
    for _, file in ipairs(context_files) do
      lines[#lines + 1] = '<project_instructions path="'
        .. escape_attr(file.path)
        .. '">\n'
        .. (file.content or "")
        .. "\n</project_instructions>"
    end
    section("project_context", table.concat(lines, "\n\n"))
  end
  local reader = have.read and "read" or (have.bash and "bash" or nil)
  if reader then
    local visible = {}
    for _, skill in ipairs(resources.skills()) do
      if not skill.disable_model_invocation then
        visible[#visible + 1] = skill
      end
    end
    if #visible > 0 then
      local lines = {
        "The following skills provide specialized instructions for specific tasks.",
        reader == "read"
            and "Use the read tool to load a skill's file when the task matches its description."
          or "Use bash to load a skill's file when the task matches its description.",
        "When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
        "",
        "<available_skills>",
      }
      for _, skill in ipairs(visible) do
        lines[#lines + 1] = "  <skill>\n    <name>"
          .. escape_attr(skill.name)
          .. "</name>\n    <description>"
          .. escape_attr(skill.description)
          .. "</description>\n    <location>"
          .. escape_attr(skill.path)
          .. "</location>\n  </skill>"
      end
      lines[#lines + 1] = "</available_skills>"
      section("skills", table.concat(lines, "\n"))
    end
  end
  section("cwd", platform.native_cwd():gsub("\\", "/"))
  if platform.is_windows() then
    section("host_context", table.concat(platform.host_context_lines(), "\n"))
  end
  local result = prelude.ordered_object(order, sections)
  local original = projection.system_text({ sections = result })
  local transformed = original
  for _, fn in ipairs(transformers) do
    local value = fn(transformed)
    if type(value) == "string" and value ~= "" then
      transformed = value
    end
  end
  if transformed ~= original then
    return prelude.ordered_object({ "preamble" }, { preamble = transformed })
  end
  return result
end

function M.system_prompt()
  return projection.system_text({ sections = M.system_sections() })
end

local function equal(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for key, value in pairs(a) do
    if not equal(value, b[key]) then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

-- Full declarations/checkpoints avoid a delta-writing subsystem. Foreign
-- declarations are data, never executable registrations.
function M.prepare_checkpoint()
  local previous = session.current_system()
  local sections, declarations = M.system_sections(), prelude.as_array({})
  for _, tool in ipairs(tools.active()) do
    declarations[#declarations + 1] = {
      name = tool.name,
      description = tool.description,
      parameters = projection.copy(tool.input_schema),
    }
  end
  local managed = {
    preamble = true,
    tools = true,
    rules = true,
    docs = true,
    addendum = true,
    project_context = true,
    skills = true,
    cwd = true,
    host_context = true,
  }
  local section_order = projection.keys(sections)
  for _, name in ipairs(projection.keys(previous and previous.sections or {})) do
    if not managed[name] then
      sections[name] = previous.sections[name]
      section_order[#section_order + 1] = name
    end
  end
  sections = prelude.ordered_object(section_order, sections)
  local patch = projection.copy(sections)
  local order = projection.keys(patch)
  for _, name in ipairs(projection.keys(previous and previous.sections or {})) do
    if patch[name] == nil then
      order[#order + 1] = name
      patch[name] = psi.json_null
    end
  end
  patch = prelude.ordered_object(order, patch)
  if
    not previous
    or not equal(previous.sections, sections)
    or not equal(previous.toolsAdded, declarations)
  then
    local removed = prelude.as_array({})
    for _, tool in ipairs(previous and previous.toolsAdded or {}) do
      removed[#removed + 1] = { name = tool.name }
    end
    session.append_system({
      role = "system",
      content = "",
      sections = patch,
      toolsAdded = declarations,
      toolsRemoved = removed,
      timestamp = math.floor(os.time() * 1000),
    })
  end
  return projection.system_text(session.current_system())
end

-- Prompts ported verbatim from pi-mono
-- (packages/coding-agent/src/core/compaction/{utils,compaction}.ts)
-- under MIT (c) 2025 Mario Zechner.

local COMPACTION_SYSTEM = table.concat({
  "You are a context summarization assistant. ",
  "Your task is to read a conversation between a user and an AI assistant, ",
  "then produce a structured summary following the exact format specified.\n\n",
  "Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ",
  "ONLY output the structured summary.",
})

local SUMMARIZATION_INSTRUCTIONS = table.concat({
  "The messages above are a conversation to summarize. ",
  "Create a structured context checkpoint summary that another LLM will use to continue the work.\n\n",
  "Use this EXACT format:\n\n",
  "## Goal\n",
  "[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]\n\n",
  "## Constraints & Preferences\n",
  "- [Any constraints, preferences, or requirements mentioned by user]\n",
  '- [Or "(none)" if none were mentioned]\n\n',
  "## Progress\n",
  "### Done\n",
  "- [x] [Completed tasks/changes]\n\n",
  "### In Progress\n",
  "- [ ] [Current work]\n\n",
  "### Blocked\n",
  "- [Issues preventing progress, if any]\n\n",
  "## Key Decisions\n",
  "- **[Decision]**: [Brief rationale]\n\n",
  "## Next Steps\n",
  "1. [Ordered list of what should happen next]\n\n",
  "## Critical Context\n",
  "- [Any data, examples, or references needed to continue]\n",
  '- [Or "(none)" if not applicable]\n\n',
  "Keep each section concise. Preserve exact file paths, function names, and error messages.",
})

local UPDATE_SUMMARIZATION_INSTRUCTIONS = table.concat({
  "Update the previous summary with the new conversation messages. ",
  "Preserve important information from the previous summary while adding new progress, ",
  "decisions, constraints, and next steps.\n\n",
  SUMMARIZATION_INSTRUCTIONS,
})

local TURN_PREFIX_INSTRUCTIONS = table.concat({
  "This is the PREFIX of a turn that was too large to keep. ",
  "The SUFFIX (recent work) is retained.\n\n",
  "Summarize the prefix to provide context for the retained suffix:\n\n",
  "## Original Request\n",
  "[What did the user ask for in this turn?]\n\n",
  "## Early Progress\n",
  "- [Key decisions and work done in the prefix]\n\n",
  "## Context for Suffix\n",
  "- [Information needed to understand the kept suffix]\n\n",
  "Be concise. Focus on what's needed to understand the kept suffix.",
})

local function safe_json(value)
  local ok, encoded = pcall(psi.json_encode, value)
  return ok and encoded or "[unserializable]"
end

local function content_text(content)
  local out = {}
  if type(content) == "string" then
    return content
  end
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      out[#out + 1] = block.text
    end
  end
  return table.concat(out)
end

local function serialize_compaction_messages(messages)
  local buf = {}
  for _, entry in ipairs(messages or {}) do
    local body = prelude.safe_json_decode(entry.data, nil, true)
    local message = type(body) == "table" and body.message or nil
    if type(message) ~= "table" then
      if entry.text and entry.text ~= "" then
        buf[#buf + 1] = session.role_prefix(entry) .. entry.text
      end
    elseif message.role == "user" or message.role == "custom" then
      local text = content_text(message.content)
      if text ~= "" then
        buf[#buf + 1] = "[User]: " .. text
      end
    elseif message.role == "assistant" then
      local tool_summaries = {}
      local text = {}
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if block.type == "text" and type(block.text) == "string" then
          text[#text + 1] = block.text
        elseif block.type == "toolCall" then
          local args = {}
          local arguments = type(block.arguments) == "table" and block.arguments or {}
          for _, key in ipairs(projection.keys(arguments)) do
            args[#args + 1] = tostring(key) .. "=" .. safe_json(arguments[key])
          end
          tool_summaries[#tool_summaries + 1] = tostring(block.name or "")
            .. "("
            .. table.concat(args, ", ")
            .. ")"
        end
      end
      if #text > 0 then
        buf[#buf + 1] = "[Assistant]: " .. table.concat(text, "\n")
      end
      if #tool_summaries > 0 then
        buf[#buf + 1] = "[Assistant tool calls]: " .. table.concat(tool_summaries, "; ")
      end
    elseif message.role == "branchSummary" or message.role == "compactionSummary" then
      buf[#buf + 1] = "[User]: " .. projection.summary_text(message.role, message.summary)
    elseif message.role == "toolResult" then
      local text = projection.truncate_for_summary(content_text(message.content), 2000)
      if text ~= "" then
        buf[#buf + 1] = "[Tool result]: " .. text
      end
    end
  end
  return table.concat(buf, "\n\n")
end

-- Returns {system_prompt, user_prompt} used by the Anthropic compaction call.
-- User message wraps the transcript in <conversation> tags and appends
-- the structured-summary instructions, mirroring pi's generateSummary.
function M.compaction_request(plan)
  if type(plan) ~= "table" then
    plan = session.prepare_compaction({ keep_recent_messages = plan })
  end
  plan = plan or {}
  local transcript = serialize_compaction_messages(plan.messages_to_summarize)
  local previous = plan.previous_summary
  local instructions = previous and UPDATE_SUMMARIZATION_INSTRUCTIONS or SUMMARIZATION_INSTRUCTIONS
  local user_prompt = "<conversation>\n" .. transcript .. "\n</conversation>\n\n"
  if previous and previous ~= "" then
    user_prompt = user_prompt .. "<previous-summary>\n" .. previous .. "\n</previous-summary>\n\n"
  end
  user_prompt = user_prompt .. instructions
  return { COMPACTION_SYSTEM, user_prompt }
end

function M.turn_prefix_request(plan)
  local transcript = serialize_compaction_messages(type(plan) == "table" and plan.turn_prefix or {})
  return {
    COMPACTION_SYSTEM,
    "<conversation>\n" .. transcript .. "\n</conversation>\n\n" .. TURN_PREFIX_INSTRUCTIONS,
  }
end

function M.format_file_operations(read_files, modified_files)
  local sections = {}
  if type(read_files) == "table" and #read_files > 0 then
    sections[#sections + 1] = "<read-files>\n"
      .. table.concat(read_files, "\n")
      .. "\n</read-files>"
  end
  if type(modified_files) == "table" and #modified_files > 0 then
    sections[#sections + 1] = "<modified-files>\n"
      .. table.concat(modified_files, "\n")
      .. "\n</modified-files>"
  end
  if #sections == 0 then
    return ""
  end
  return "\n\n" .. table.concat(sections, "\n\n")
end

local BRANCH_SUMMARY_PREAMBLE = table.concat({
  "The user explored a different conversation branch before returning here.\n",
  "Summary of that exploration:\n\n",
})

local BRANCH_SUMMARY_INSTRUCTIONS = table.concat({
  "Create a structured summary of this conversation branch for context when returning later.\n\n",
  "Use this EXACT format:\n\n",
  "## Goal\n",
  "[What was the user trying to accomplish in this branch?]\n\n",
  "## Constraints & Preferences\n",
  "- [Any constraints, preferences, or requirements mentioned]\n",
  '- [Or "(none)" if none were mentioned]\n\n',
  "## Progress\n### Done\n",
  "- [x] [Completed tasks/changes]\n\n",
  "### In Progress\n- [ ] [Work that was started but not finished]\n\n",
  "### Blocked\n- [Issues preventing progress, if any]\n\n",
  "## Key Decisions\n- **[Decision]**: [Brief rationale]\n\n",
  "## Next Steps\n1. [What should happen next to continue this work]\n\n",
  "Keep each section concise. Preserve exact file paths, function names, and error messages.",
})

function M.branch_summary_request(messages, custom_instructions)
  local text = serialize_compaction_messages(messages)
  local instructions = BRANCH_SUMMARY_INSTRUCTIONS
  if type(custom_instructions) == "string" and custom_instructions ~= "" then
    instructions = instructions .. "\n\nAdditional focus: " .. custom_instructions
  end
  local user_prompt = "<conversation>\n" .. text .. "\n</conversation>\n\n" .. instructions
  return { COMPACTION_SYSTEM, user_prompt, BRANCH_SUMMARY_PREAMBLE }
end

function M.runtime_summary()
  local info = psi.runtime_info()
  local buf = {
    "psi Lua runtime\n",
    "version: ",
    info.version,
    "\n",
    "boot-file: ",
    info["boot-file"] or "<none>",
    "\n",
    "current-date: ",
    info["current-date"],
    "\n",
    "current-working-directory: ",
    platform.to_host_path(info["current-working-directory"]),
    "\n",
    "session-path: ",
    psi.session_path and (psi.session_path() or "<none>") or "<unavailable>",
    "\n",
    "platform-windows: ",
    tostring(psi.platform and psi.platform.is_windows and psi.platform.is_windows() or false),
    "\n",
    "session-message-count: ",
    tostring(info["session-message-count"]),
    "\n",
    "host-primitives (available as psi.<name>, not globals):\n",
  }
  for _, name in ipairs(info.primitives) do
    buf[#buf + 1] = "- " .. name .. "\n"
  end
  buf[#buf + 1] = "tool-specs:\n"
  for _, t in ipairs(tools.all()) do
    buf[#buf + 1] = "- " .. t.name .. ": " .. t.description .. "\n"
  end
  return table.concat(buf)
end

function M.help_text()
  return require("psi.slash_commands").help_text()
end

function M.hotkeys_text()
  return require("psi.keybindings").hotkeys_text()
end

-- Bootstrap print-mode handler (called by C with the user's prompt).
function M.handle_print(prompt)
  return table.concat({
    "psi bootstrap online\n",
    "version: ",
    psi.version(),
    "\n",
    "session-messages: ",
    tostring(psi.session_message_count()),
    "\n",
    "prompt: ",
    prompt,
  })
end

return M
