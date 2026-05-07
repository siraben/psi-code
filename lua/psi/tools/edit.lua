-- psi.tools.edit: Read-then-write a file in place via exact-match string substitution.

local records = require("psi.records")
local registry = require("psi.tool_registry")
local prelude = require("psi.prelude")
local path_util = require("psi.path_utils")
local mutation_queue = require("psi.file_mutation_queue")
local helpers = require("psi.tool_helpers")
local diff = require("psi.diff")

local function impl(input)
  local raw_path = registry.require_string(input, "path")
  if not raw_path then
    return records.tool_failure("edit", "missing string field: path")
  end
  local path = path_util.resolve(raw_path) or raw_path
  local edits = input.edits
  local old_text, new_text = input.oldText, input.newText

  return mutation_queue.with_path(path, function()
    local original = prelude.safe_read(path)
    if not original then
      return records.tool_failure("edit", "could not read file")
    end

    local edits_to_apply, replacements
    if type(edits) == "table" and #edits > 0 then
      edits_to_apply = diff.edits_from_input({ edits = edits })
      replacements = edits_to_apply and #edits_to_apply or nil
    elseif type(old_text) == "string" and type(new_text) == "string" then
      edits_to_apply = diff.edits_from_input({ oldText = old_text, newText = new_text })
      replacements = edits_to_apply and 1 or nil
    elseif type(old_text) ~= "string" then
      return records.tool_failure("edit", "missing string field: oldText")
    elseif type(new_text) ~= "string" then
      return records.tool_failure("edit", "missing string field: newText")
    end

    if not edits_to_apply then
      return records.tool_failure("edit", "invalid edits")
    end
    local preview, preview_err = diff.preview_edits(original, edits_to_apply, raw_path)
    if not preview then
      return records.tool_failure("edit", preview_err or "target text not found")
    end
    if not psi.file_write(path, preview.output) then
      return records.tool_failure("edit", "could not write full file")
    end
    return records.new_tool_result(true, "edit", nil, {
      path = raw_path,
      resolved_path = path,
      replacements = replacements,
      diff = preview.diff,
      firstChangedLine = preview.firstChangedLine,
    })
  end)
end

return function()
  local edit_item_schema = helpers.schema_object({
    oldText = helpers.schema_type("string"),
    newText = helpers.schema_type("string"),
  }, { "oldText", "newText" })

  helpers.register(registry, records, {
    name = "edit",
    description = "Edit a single file using exact text replacement. Prefer small, precise edits over broad rewrites.",
    prompt_snippet = "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
    guidelines = {
      "Use edit for precise changes where old text can be matched exactly.",
      "When changing multiple separate locations in one file, use one edit call with multiple entries in edits[].",
      "Keep edits[].oldText as small as possible while still being unique in the file.",
    },
    input_schema = helpers.schema_object({
      path = helpers.schema_type("string"),
      edits = { type = "array", items = edit_item_schema },
    }, { "path", "edits" }),
    impl = impl,
  })
end
