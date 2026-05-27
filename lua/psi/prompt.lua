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
  local custom_path, custom_prompt = resources.system_prompt_file()
  local append_path, append_prompt = resources.append_system_prompt_file()

  -- Honour psi.tools.set_active(...): the "Available tools:" list
  -- must mirror what the model can actually dispatch, and the
  -- guideline inference (grep/find/ls vs bash) must key off the
  -- active set too — not the full registry. Mirrors pi's
  -- `selectedTools` option in buildSystemPrompt.
  local all_tools = tools.active()
  local have = tool_set(all_tools)

  local buf = { custom_prompt or PREAMBLE, "\n\nAvailable tools:\n" }
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

  local host_lines = platform.host_context_lines()
  if #host_lines > 0 then
    buf[#buf + 1] = "\nHost context:\n"
    for _, line in ipairs(host_lines) do
      write_line(buf, "- ", line)
    end
  end

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

local function build_compaction_transcript(keep_recent)
  local messages = session.messages()
  local total = #messages
  local to_drop = total - keep_recent
  local head = to_drop > 0 and prelude.take(messages, to_drop) or {}
  local buf = {}
  for _, m in ipairs(head) do
    buf[#buf + 1] = session.role_prefix(m) .. m.text .. "\n"
  end
  return table.concat(buf)
end

-- Returns {system_prompt, user_prompt} used by the Anthropic compaction call.
-- User message wraps the transcript in <conversation> tags and appends
-- the structured-summary instructions, mirroring pi's generateSummary.
function M.compaction_request(keep_recent)
  local transcript = build_compaction_transcript(keep_recent)
  local user_prompt = "<conversation>\n"
    .. transcript
    .. "\n</conversation>\n\n"
    .. SUMMARIZATION_INSTRUCTIONS
  return { COMPACTION_SYSTEM, user_prompt }
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
