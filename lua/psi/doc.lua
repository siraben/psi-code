-- psi.doc: self-documenting registry, Emacs-style.
--
-- The model is `C-h f` / `M-x describe-function`: every named entity
-- in psi (slash command, host primitive, tool, keybinding action,
-- provider) has a docstring queryable at runtime. There is no
-- separate doc file; the doc *is* the running registry.
--
-- Sources:
--
--   psi.doc.set(key, doc, opts)   register/override a doc entry
--   psi.doc.get(key)              retrieve {kind, doc, source} or nil
--   psi.doc.all()                 array of all known keys
--   psi.doc.apropos(pattern)      array of {key, kind, doc} matching
--                                 the pattern in name OR doc body
--
-- Auto-population (`psi.doc.bootstrap`) harvests from the existing
-- in-memory registries:
--
--   - psi.commands.builtin_commands()        -> kind="command"
--   - psi.tools.all()                        -> kind="tool"
--   - psi.keybindings.definitions()          -> kind="key"
--   - psi.providers.all_providers()          -> kind="provider"
--   - psi.__doc_host (PSI_REG_DOC sites)     -> kind="primitive"
--
-- The /describe and /apropos slash commands sit on top.

local M = {}

local entries = {} -- key -> {kind, doc, source, extra}

local function set(key, kind, doc, opts)
  if type(key) ~= "string" or key == "" then
    return
  end
  if type(doc) ~= "string" then
    doc = ""
  end
  entries[key] = {
    kind = kind or "other",
    doc = doc,
    source = opts and opts.source or nil,
    extra = opts and opts.extra or nil,
  }
end

function M.set(key, doc, opts)
  set(key, opts and opts.kind or "other", doc, opts)
end

function M.get(key)
  return entries[key]
end

function M.all()
  local keys = {}
  for k in pairs(entries) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local function lc(s)
  return type(s) == "string" and s:lower() or ""
end

function M.apropos(pattern)
  if type(pattern) ~= "string" or pattern == "" then
    return {}
  end
  local needle = pattern:lower()
  local hits = {}
  for k, v in pairs(entries) do
    if lc(k):find(needle, 1, true) or lc(v.doc):find(needle, 1, true) then
      hits[#hits + 1] = { key = k, kind = v.kind, doc = v.doc, source = v.source }
    end
  end
  table.sort(hits, function(a, b)
    if a.kind == b.kind then
      return a.key < b.key
    end
    return a.kind < b.kind
  end)
  return hits
end

-- ---------------------------------------------------------- bootstrap --

local function safe_call(fn)
  if type(fn) ~= "function" then
    return nil
  end
  local ok, value = pcall(fn)
  if not ok then
    return nil
  end
  return value
end

local function bootstrap_commands(commands)
  local list = safe_call(commands and commands.builtin_commands)
  if type(list) ~= "table" then
    return
  end
  for _, cmd in ipairs(list) do
    if cmd and type(cmd.name) == "string" then
      local key = "/" .. cmd.name
      local doc = cmd.description or ""
      if cmd.argument_hint and cmd.argument_hint ~= "" then
        doc = (doc ~= "" and (doc .. "  ") or "") .. "args: " .. cmd.argument_hint
      end
      set(key, "command", doc, { source = "lua/psi/slash_commands.lua", extra = cmd })
    end
  end
end

local function bootstrap_tools(tools)
  local list = safe_call(tools and tools.all)
  if type(list) ~= "table" then
    return
  end
  for _, tool in ipairs(list) do
    if tool and type(tool.name) == "string" then
      local doc = tool.description or ""
      doc = doc:match("^[^\n]+") or doc
      set("tool:" .. tool.name, "tool", doc, {
        source = "lua/psi/tools/" .. tool.name .. ".lua",
        extra = tool,
      })
    end
  end
end

local function bootstrap_keybindings(keybindings)
  local list = safe_call(keybindings and keybindings.definitions)
  if type(list) ~= "table" then
    return
  end
  for _, def in ipairs(list) do
    if def and type(def.id) == "string" then
      set(def.id, "key", def.description or "", {
        source = "lua/psi/keybindings.lua",
        extra = def,
      })
    end
  end
end

local function bootstrap_providers(providers)
  local list = safe_call(providers and providers.all_providers)
  if type(list) ~= "table" then
    return
  end
  for _, entry in ipairs(list) do
    if entry and type(entry.name) == "string" then
      local spec = providers.provider and providers.provider(entry.name) or {}
      local auth = {}
      if type(spec.auth) == "table" and type(spec.auth.oauth) == "table" then
        auth[#auth + 1] = "OAuth via /login " .. entry.name
      end
      if type(spec.auth) == "table" and type(spec.auth.api_key) == "table" then
        local env = spec.auth.api_key.env
        local suffix = type(env) == "string" and (" or " .. env) or ""
        auth[#auth + 1] = "API key via /login " .. entry.name .. suffix
      end
      if #auth == 0 then
        auth[1] = "no login required"
      end
      local doc = string.format(
        "default model %s; override via %s; auth: %s",
        spec.default_model or "?",
        spec.model_env or "—",
        table.concat(auth, ", ")
      )
      set("provider:" .. entry.name, "provider", doc, {
        source = "lua/psi/api_registry.lua",
        extra = spec,
      })
    end
  end
end

local function bootstrap_host_primitives()
  local doc_table = rawget(psi, "__doc_host")
  if type(doc_table) ~= "table" then
    return
  end
  for name, doc in pairs(doc_table) do
    if type(name) == "string" and type(doc) == "string" then
      set("psi." .. name, "primitive", doc, { source = "src/lua/vm.c" })
    end
  end
end

-- Re-runnable; later calls replace earlier entries with the same key.
function M.bootstrap(p)
  p = p or psi
  bootstrap_commands(p.commands)
  bootstrap_tools(p.tools)
  bootstrap_keybindings(p.keybindings)
  bootstrap_providers(p.providers)
  bootstrap_host_primitives()
end

return M
