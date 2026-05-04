-- gen-docs.lua: regenerate the auto-generated sections of psi's docs
-- and emit psi.1.
--
-- Source of truth lives in Lua (slash commands, keybindings, tools,
-- provider registry) and in C (argtable3 calls in src/runtime/cli.c,
-- PSI_REG calls in src/lua/vm.c). This script introspects those
-- sources and rewrites the regions between
--   <!-- @generated:NAME -->
--   ...
--   <!-- @end -->
-- markers in the relevant markdown files.
--
-- Run via:
--   ./build/psi --eval 'dofile("scripts/gen-docs.lua")'
--
-- Or `make docs` / `make check-docs` (the latter asserts no diff).

local slash = require("psi.slash_commands")
local keybindings = require("psi.keybindings")
local tools = require("psi.tools")
local api_registry = require("psi.api_registry")

local M = {}

-- ---------------------------------------------------------------- io --

local function read_file(path)
  local fh, err = io.open(path, "rb")
  if not fh then
    error("read: " .. tostring(err))
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

local function write_file(path, body)
  local fh, err = io.open(path, "wb")
  if not fh then
    error("write: " .. tostring(err))
  end
  fh:write(body)
  fh:close()
end

local function escape_pat(s)
  return (s:gsub("([^%w])", "%%%1"))
end

local function replace_region(body, name, replacement)
  local marker_open = "<!%-%- @generated:" .. escape_pat(name) .. " %-%->"
  local marker_close = "<!%-%- @end %-%->"
  local pat = "(" .. marker_open .. "\n).-(" .. marker_close .. ")"
  local trimmed = replacement:gsub("\n+$", "")
  local replaced, n = body:gsub(pat, function(open, close)
    return open .. trimmed .. "\n" .. close
  end)
  if n == 0 then
    error(("region @generated:%s not found"):format(name))
  end
  return replaced
end

-- -------------------------------------------------------- generators --

local function fmt_aliases(cmd)
  if not cmd.aliases or #cmd.aliases == 0 then
    return ""
  end
  local parts = {}
  for _, a in ipairs(cmd.aliases) do
    if a:sub(1, 1) == ":" then
      parts[#parts + 1] = a
    else
      parts[#parts + 1] = "/" .. a
    end
  end
  return table.concat(parts, ", ")
end

function M.slash_commands_table()
  local cmds = slash.builtin_commands()
  local lines = {
    "| Command | Aliases | Args | Description |",
    "|---|---|---|---|",
  }
  for _, cmd in ipairs(cmds) do
    lines[#lines + 1] = string.format(
      "| `/%s` | %s | %s | %s |",
      cmd.name,
      fmt_aliases(cmd) ~= "" and "`" .. fmt_aliases(cmd) .. "`" or "—",
      cmd.argument_hint and "`" .. cmd.argument_hint .. "`" or "—",
      cmd.description or ""
    )
  end
  return table.concat(lines, "\n")
end

function M.keybindings_table()
  local defs = keybindings.definitions()
  local sections = {}
  for _, def in ipairs(defs) do
    sections[def.section] = sections[def.section] or {}
    table.insert(sections[def.section], def)
  end
  local order = { "Navigation", "Editing", "Other" }
  local lines = {}
  for _, section in ipairs(order) do
    if sections[section] then
      lines[#lines + 1] = string.format("**%s**", section)
      lines[#lines + 1] = ""
      lines[#lines + 1] = "| Action | Default keys | Description |"
      lines[#lines + 1] = "|---|---|---|"
      for _, def in ipairs(sections[section]) do
        local keys = {}
        for _, k in ipairs(def.default_keys or {}) do
          keys[#keys + 1] = "`" .. k .. "`"
        end
        local key_text = #keys > 0 and table.concat(keys, ", ") or "—"
        lines[#lines + 1] = string.format(
          "| `%s` | %s | %s |",
          def.id,
          key_text,
          def.description or ""
        )
      end
      lines[#lines + 1] = ""
    end
  end
  return (table.concat(lines, "\n"):gsub("\n+$", ""))
end

function M.tools_list()
  local all = tools.all()
  local names = {}
  for _, t in ipairs(all) do
    names[#names + 1] = t.name
  end
  table.sort(names)
  local lines = {}
  for _, name in ipairs(names) do
    local tool = tools.find(name)
    local desc = tool and tool.description or ""
    lines[#lines + 1] = string.format("- `%s` — %s", name, desc:match("^[^\n]+") or "")
  end
  return table.concat(lines, "\n")
end

function M.providers_table()
  local entries = api_registry.all_providers()
  local lines = {
    "| Provider | Default model | Model env override |",
    "|---|---|---|",
  }
  for _, entry in ipairs(entries) do
    local spec = api_registry.provider(entry.name)
    lines[#lines + 1] = string.format(
      "| `%s` | `%s` | `%s` |",
      entry.name,
      (spec and spec.default_model) or "—",
      (spec and spec.model_env) or "—"
    )
  end
  return table.concat(lines, "\n")
end

function M.providers_list_inline()
  local entries = api_registry.all_providers()
  local names = {}
  for _, entry in ipairs(entries) do
    names[#names + 1] = entry.name
  end
  return "`" .. table.concat(names, "`, `") .. "`"
end

-- ----------------------------------------------------------- C parsing --

local function parse_cli_options(source)
  local opts = {}
  for short, long, var, desc in
    source:gmatch('arg_str0%(([^,]+),%s*"([%w-]+)",%s*"([^"]+)",%s*"([^"]-)"%)')
  do
    opts[#opts + 1] = {
      kind = "str",
      short = short:match('"(.-)"'),
      long = long,
      var = var,
      desc = desc,
    }
  end
  for short, long, desc in
    source:gmatch('arg_lit0%(([^,]+),%s*"([%w-]+)",%s*"([^"]-)"%)')
  do
    opts[#opts + 1] = {
      kind = "lit",
      short = short:match('"(.-)"'),
      long = long,
      desc = desc,
    }
  end
  for short, long, var, desc in
    source:gmatch('arg_int0%(([^,]+),%s*"([%w-]+)",%s*"([^"]+)",%s*"([^"]-)"%)')
  do
    opts[#opts + 1] = {
      kind = "int",
      short = short:match('"(.-)"'),
      long = long,
      var = var,
      desc = desc,
    }
  end
  table.sort(opts, function(a, b)
    return a.long < b.long
  end)
  return opts
end

function M.cli_options_table()
  local source = read_file("src/runtime/cli.c")
  local opts = parse_cli_options(source)
  local lines = {
    "| Flag | Argument | Description |",
    "|---|---|---|",
  }
  for _, opt in ipairs(opts) do
    local flag
    if opt.short and opt.short ~= "" then
      flag = string.format("`-%s`, `--%s`", opt.short, opt.long)
    else
      flag = string.format("`--%s`", opt.long)
    end
    local arg = opt.var and ("`" .. opt.var .. "`") or "—"
    lines[#lines + 1] = string.format("| %s | %s | %s |", flag, arg, opt.desc)
  end
  return table.concat(lines, "\n")
end

-- ------------------------------------------------- psi.* primitives --

local function parse_psi_reg(source)
  local names = {}
  for name in source:gmatch('PSI_REG%("([%w_]+)"') do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

function M.psi_primitives_list()
  local source = read_file("src/lua/vm.c")
  local names = parse_psi_reg(source)
  local cols = 3
  local lines = {}
  for i = 1, #names, cols do
    local row = {}
    for j = 0, cols - 1 do
      if names[i + j] then
        row[#row + 1] = "`psi." .. names[i + j] .. "`"
      end
    end
    lines[#lines + 1] = table.concat(row, " · ")
  end
  return table.concat(lines, "  \n")
end

-- ------------------------------------------------------- man page --

local function man_escape(s)
  return (s:gsub("\\", "\\\\"):gsub("%-", "\\-"))
end

function M.man_page()
  local out = {}
  local function emit(fmt, ...)
    out[#out + 1] = string.format(fmt, ...)
  end
  emit('.\\" Auto-generated by scripts/gen-docs.lua. Do not edit by hand.')
  emit(".TH PSI 1 \"\" \"psi\" \"User Commands\"")
  emit(".SH NAME")
  emit("psi \\- terminal coding agent")
  emit(".SH SYNOPSIS")
  emit(".B psi")
  emit("[\\fIoptions\\fR] [\\fImessage\\fR]")
  emit(".SH DESCRIPTION")
  emit("psi is a small terminal coding agent. The host runtime is C89;")
  emit("the agent loop, providers, and TUI are pure Lua. With no flags,")
  emit("psi opens the full-screen TUI over the same runtime that")
  emit("\\fB--print\\fR, \\fB--agent\\fR, and \\fB--repl\\fR drive.")
  emit(".SH OPTIONS")
  local cli = parse_cli_options(read_file("src/runtime/cli.c"))
  for _, opt in ipairs(cli) do
    local label
    if opt.short and opt.short ~= "" then
      label = string.format("\\fB-%s\\fR, \\fB\\-\\-%s\\fR", opt.short, opt.long)
    else
      label = string.format("\\fB\\-\\-%s\\fR", opt.long)
    end
    if opt.var then
      label = label .. " \\fI" .. opt.var .. "\\fR"
    end
    emit(".TP")
    emit(label)
    emit(man_escape(opt.desc))
  end
  emit(".SH SLASH COMMANDS")
  emit("Available inside the interactive shell and TUI:")
  emit(".PP")
  for _, cmd in ipairs(slash.builtin_commands()) do
    emit(".TP")
    local args = cmd.argument_hint and (" " .. cmd.argument_hint) or ""
    emit("\\fB/%s%s\\fR", cmd.name, args)
    emit(man_escape(cmd.description or ""))
    if cmd.aliases and #cmd.aliases > 0 then
      local aliases = {}
      for _, a in ipairs(cmd.aliases) do
        aliases[#aliases + 1] = "/" .. a
      end
      emit("Aliases: %s", table.concat(aliases, ", "))
    end
  end
  emit(".SH PROVIDERS")
  local providers = api_registry.all_providers()
  local pnames = {}
  for n in pairs(providers) do
    pnames[#pnames + 1] = n
  end
  table.sort(pnames)
  for _, name in ipairs(pnames) do
    local spec = providers[name]
    emit(".TP")
    emit("\\fB%s\\fR", name)
    emit(
      "default model %s, override via %s",
      spec.default_model or "n/a",
      spec.model_env or "—"
    )
  end
  emit(".SH ENVIRONMENT")
  emit(".TP")
  emit("\\fBPSI_PROVIDER\\fR")
  emit("Override default provider: " .. table.concat(pnames, ", ") .. ".")
  emit(".TP")
  emit("\\fBPSI_EXTENSIONS_DIR\\fR")
  emit("Colon-separated list of extension directories scanned at boot.")
  emit(".TP")
  emit("\\fBANTHROPIC_API_KEY\\fR")
  emit("Required for the Anthropic provider.")
  emit(".SH FILES")
  emit(".TP")
  emit("\\fI~/.config/psi/settings.json\\fR")
  emit("User-level layered settings.")
  emit(".TP")
  emit("\\fI./.psi/settings.json\\fR")
  emit("Project-level settings (overrides user).")
  emit(".TP")
  emit("\\fI~/.config/psi/extensions/\\fR, \\fI./.psi/extensions/\\fR")
  emit("Lua extensions loaded at boot.")
  emit(".SH SEE ALSO")
  emit("Documentation under \\fIdocs/\\fR: architecture.md, extensions.md,")
  emit("portability.md, port-status.md, providers.md.")
  return table.concat(out, "\n") .. "\n"
end

-- ---------------------------------------------------------- driver --

local function update(path, regions)
  local body = read_file(path)
  for name, content in pairs(regions) do
    body = replace_region(body, name, content)
  end
  write_file(path, body)
  print("updated " .. path)
end

local function run()
  update("README.md", {
    ["builtin-tools"] = M.tools_list(),
    ["providers-inline"] = M.providers_list_inline(),
  })
  update("docs/extensions.md", {
    ["slash-commands"] = M.slash_commands_table(),
    ["keybindings"] = M.keybindings_table(),
  })
  update("docs/providers.md", {
    ["providers-table"] = M.providers_table(),
  })
  update("docs/architecture.md", {
    ["host-primitives"] = M.psi_primitives_list(),
    ["cli-options"] = M.cli_options_table(),
  })
  write_file("psi.1", M.man_page())
  print("wrote psi.1")
end

run()
return M
