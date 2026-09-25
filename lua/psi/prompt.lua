-- psi.prompt: system prompt, compaction request, runtime summary, help text.

local prelude = require("psi.prelude")
local session = require("psi.session_manager")
local tools = require("psi.tools")
local resources = require("psi.resource_loader")
local platform = require("psi.platform")

local M = {}

function M.find_context_files()
  return resources.context_files()
end

-- ---------- system prompt ----------
--
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
  value = value:gsub('"', "&quot;")
  value = value:gsub("<", "&lt;")
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

function M.system_prompt()
  local _, custom_prompt = resources.system_prompt_file()
  local append_path, append_prompt = resources.append_system_prompt_file()
  local has_custom_prompt = custom_prompt ~= nil and custom_prompt ~= ""

  -- Honour psi.tools.set_active(...): the "Available tools:" list
  -- must mirror what the model can actually dispatch, and the
  -- guideline inference (grep/find/ls vs bash) must key off the
  -- active set too — not the full registry. Mirrors pi's
  -- `selectedTools` option in buildSystemPrompt.
  local all_tools = tools.active()
  local have = tool_set(all_tools)

  local buf = { has_custom_prompt and custom_prompt or PREAMBLE }
  -- A project SYSTEM.md replaces the built-in prompt, including its tool
  -- list, rules, and documentation section. The actual tool schemas are
  -- still sent separately by the provider.
  if not has_custom_prompt then
    buf[#buf + 1] = "\n\nAvailable tools:\n"
    if #all_tools == 0 then
      buf[#buf + 1] = "(none)\n"
    end
    for _, t in ipairs(all_tools) do
      buf[#buf + 1] = "- " .. t.name .. ": " .. t.prompt_snippet .. "\n"
    end
    buf[#buf + 1] =
      "\nIn addition to the tools above, you may have access to other custom tools depending on the project.\n"

    buf[#buf + 1] = "\nGuidelines:\n"
    local seen = {}
    local function add_guideline(g)
      if g == nil or g == "" or seen[g] then
        return
      end
      seen[g] = true
      write_line(buf, "- ", g)
    end
    add_guideline(exploration_guideline(have))
    for _, t in ipairs(all_tools) do
      for _, g in ipairs(t.guidelines or {}) do
        add_guideline(g)
      end
    end
    for _, g in ipairs(BASE_GUIDELINES) do
      add_guideline(g)
    end
  end

  local host_lines = platform.host_context_lines()
  if #host_lines > 0 then
    buf[#buf + 1] = "\nHost context:\n"
    for _, line in ipairs(host_lines) do
      write_line(buf, "- ", line)
    end
  end

  if not has_custom_prompt then
    buf[#buf + 1] = table.concat({
      "\nPsi documentation (embedded in the binary; the read tool serves ",
      "the bundled copy when the file is not on disk, so these paths ",
      "work regardless of cwd):\n",
      "- README.md                 — main documentation\n",
      "- docs/architecture.md      — architecture overview\n",
      "- docs/port-status.md       — port audit against pi\n",
      "- docs/extensions.md        — extension / event / slash-command API\n",
      "- docs/providers.md         — provider routing and configuration\n",
      "- Read only when the user asks about psi itself, its architecture, ",
      "Lua modules, or host layer. Always read the target .md file ",
      "completely and follow links to related docs.",
    })
  end

  if append_prompt and append_prompt ~= "" then
    buf[#buf + 1] = "\n\n"
    buf[#buf + 1] = append_prompt
    if append_path then
      buf[#buf + 1] = "\n"
    end
  end

  local context_files = M.find_context_files()
  if #context_files > 0 then
    buf[#buf + 1] = "\n\n<project_context>\n\nProject-specific instructions and guidelines:\n\n"
    for _, f in ipairs(context_files) do
      buf[#buf + 1] = '<project_instructions path="'
        .. escape_attr(f.path)
        .. '">\n'
        .. f.content
        .. "\n</project_instructions>\n\n"
    end
    buf[#buf + 1] = "</project_context>\n"
  end
  buf[#buf + 1] = "\nCurrent date: " .. psi.current_date()
  buf[#buf + 1] = "\nCurrent working directory: " .. platform.native_cwd()
  local out = table.concat(buf)
  for _, fn in ipairs(transformers) do
    local transformed = fn(out)
    if type(transformed) == "string" and transformed ~= "" then
      out = transformed
    end
  end
  return out
end

-- ---------- compaction request ----------
--
-- Prompts ported verbatim from pi-mono
-- (packages/coding-agent/src/core/compaction/{utils,compaction}.ts)
-- under MIT (c) 2025 Mario Zechner.

local COMPACTION_SYSTEM = table.concat({
  "You are a context summarization assistant. ",
  "Your task is to read a conversation between a user and an AI coding assistant, ",
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
    local body = prelude.safe_json_decode(entry.data, nil)
    local message = type(body) == "table" and body.message or nil
    if type(message) ~= "table" then
      if entry.text and entry.text ~= "" then
        buf[#buf + 1] = session.role_prefix(entry) .. entry.text
      end
    elseif message.role == "user" then
      local text = content_text(message.content)
      if text ~= "" then
        buf[#buf + 1] = "[User]: " .. text
      end
    elseif message.role == "assistant" then
      local thinking = {}
      local tool_summaries = {}
      local text = {}
      for _, block in ipairs(type(message.content) == "table" and message.content or {}) do
        if block.type == "thinking" and type(block.thinking) == "string" then
          thinking[#thinking + 1] = block.thinking
        elseif block.type == "text" and type(block.text) == "string" then
          text[#text + 1] = block.text
        elseif block.type == "toolCall" then
          local args = {}
          for key, value in pairs(type(block.arguments) == "table" and block.arguments or {}) do
            args[#args + 1] = tostring(key) .. "=" .. safe_json(value)
          end
          table.sort(args)
          tool_summaries[#tool_summaries + 1] = tostring(block.name or "")
            .. "("
            .. table.concat(args, ", ")
            .. ")"
        end
      end
      if #thinking > 0 then
        buf[#buf + 1] = "[Assistant thinking]: " .. table.concat(thinking, "\n")
      end
      if #text > 0 then
        buf[#buf + 1] = "[Assistant]: " .. table.concat(text)
      end
      if #tool_summaries > 0 then
        buf[#buf + 1] = "[Assistant tool calls]: " .. table.concat(tool_summaries, "; ")
      end
    elseif message.role == "toolResult" then
      local text = content_text(message.content)
      if #text > 2000 then
        text = text:sub(1, 2000)
          .. "\n\n[... "
          .. tostring(#content_text(message.content) - 2000)
          .. " more characters truncated]"
      end
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
  "## Branch Goal\n",
  "[What was the user trying to accomplish in this branch?]\n\n",
  "## Progress\n",
  "- [Completed work, discoveries, and decisions]\n\n",
  "## Files and State\n",
  "- [Relevant files read or changed, if known]\n\n",
  "## Carry Forward\n",
  "- [Important context that should be available on the destination branch]\n\n",
  "Keep it concise and preserve exact file paths, commands, errors, and identifiers.",
})

function M.branch_summary_request(messages, custom_instructions)
  local buf = {}
  for _, m in ipairs(messages or {}) do
    if type(m) == "table" and type(m.text) == "string" and m.text ~= "" then
      buf[#buf + 1] = session.role_prefix(m) .. m.text .. "\n"
    end
  end
  local instructions = BRANCH_SUMMARY_INSTRUCTIONS
  if type(custom_instructions) == "string" and custom_instructions ~= "" then
    instructions = instructions .. "\n\nAdditional focus: " .. custom_instructions
  end
  local user_prompt = "<conversation>\n"
    .. table.concat(buf)
    .. "\n</conversation>\n\n"
    .. instructions
  return { COMPACTION_SYSTEM, user_prompt, BRANCH_SUMMARY_PREAMBLE }
end

-- ---------- runtime summary and help ----------

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
