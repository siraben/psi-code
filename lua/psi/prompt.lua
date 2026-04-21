-- psi.prompt: system prompt, compaction request, runtime summary, help text.

local records = require("psi.records")
local prelude = require("psi.prelude")
local session = require("psi.session")
local tools = require("psi.tools")

local M = {}

-- ---------- project context discovery ----------

local CONTEXT_FILENAMES = { "AGENTS.md", "CLAUDE.md" }

function M.find_context_files()
  local dir = psi.cwd()
  local found = {}
  while true do
    local local_matches = {}
    for _, name in ipairs(CONTEXT_FILENAMES) do
      local path = prelude.path_join(dir, name)
      if psi.file_exists(path) then
        local_matches[#local_matches + 1] = records.new_context_file(path, psi.read_file(path))
      end
    end
    -- prepend local_matches so ancestor files come first in final order
    local merged = {}
    for _, f in ipairs(local_matches) do
      merged[#merged + 1] = f
    end
    for _, f in ipairs(found) do
      merged[#merged + 1] = f
    end
    found = merged
    local parent = psi.parent_directory(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return found
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
    return "Use bash for file operations like ls, rg, find"
  end
  if have.bash and (have.grep or have.find or have.ls) then
    return "Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)"
  end
  return nil
end

local function write_line(buf, prefix, line)
  buf[#buf + 1] = prefix .. line .. "\n"
end

function M.system_prompt()
  local all_tools = tools.all()
  local have = tool_set(all_tools)

  local buf = { PREAMBLE, "\n\nAvailable tools:\n" }
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

  buf[#buf + 1] = table.concat({
    "\nPsi documentation (read only when the user asks about psi itself, its architecture, ",
    "Lua modules, or host layer):\n",
    "- Main documentation: README.md\n",
    "- Architecture: docs/architecture.md\n",
    "- Port status: docs/port-status.md\n",
    "- When working on psi topics, read the docs and follow .md cross-references before implementing\n",
    "- Always read psi .md files completely and follow links to related docs",
  })

  local context_files = M.find_context_files()
  if #context_files > 0 then
    buf[#buf + 1] = "\n\n# Project Context\n\nProject-specific instructions and guidelines:\n\n"
    for _, f in ipairs(context_files) do
      buf[#buf + 1] = "## " .. f.path .. "\n\n" .. f.content .. "\n\n"
    end
  end
  buf[#buf + 1] = "\nCurrent date: " .. psi.current_date()
  buf[#buf + 1] = "\nCurrent working directory: " .. psi.cwd()
  return table.concat(buf)
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
    info["current-working-directory"],
    "\n",
    "session-message-count: ",
    tostring(info["session-message-count"]),
    "\n",
    "host-primitives:\n",
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

M.HELP_TEXT = table.concat({
  "/help            show available commands\n",
  "/quit            exit the shell  (aliases: /q, :quit, :q)\n",
  "/session         show current session info (id, file, model, usage)\n",
  "/new             start a fresh session in place\n",
  "/resume <path>   load a session file from disk\n",
  "/name <text>     set the session display name\n",
  "/model <spec>    switch model mid-session (e.g. ollama/llama3.1)\n",
  "/copy            copy the last assistant message to the clipboard\n",
  "/export [path]   write the session as markdown (default: sessions/<id>.md)\n",
  "/compact [N]     summarize older context, keep the most recent N messages\n",
  "/fork [N]        save the first N entries to a new session file\n",
  "/reload          re-run extension discovery\n",
  "/system-prompt   print the current coding-agent system prompt",
})

function M.help_text()
  return M.HELP_TEXT
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
