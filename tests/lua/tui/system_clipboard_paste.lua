--[==[psi-test
expect = "aX\nY    Zb|9||ab|1||a|0|aQb|2|visual|block|0"
]==]
local rt = require("psi.tui_runtime")

local pasted = rt._debug_edit_keys("ab", 1, { { key = "ctrl-v" } }, false, {
  clipboard_reader = function()
    return "X\r\nY\tZ" .. string.char(7)
  end,
})

-- Empty or unavailable clipboards are ignored without turning a normal editor
-- action into a visible error.
local unavailable = rt._debug_edit_keys("ab", 1, { { key = "ctrl-v" } }, false, {
  clipboard_reader = function()
    return nil, "clipboard unavailable"
  end,
})

-- A decoded control key inside bracketed paste remains paste data filtering;
-- it must not recursively read the system clipboard.
local bracketed_reads = 0
local bracketed = rt._debug_edit_keys(
  "",
  0,
  {
    { key = "paste-start" },
    { key = "text", text = "a" },
    { key = "ctrl-v" },
    { key = "paste-end" },
  },
  false,
  {
    clipboard_reader = function()
      bracketed_reads = bracketed_reads + 1
      return "wrong"
    end,
  }
)

-- Vim owns Ctrl-V in normal/visual mode, while insert mode still falls
-- through to the system clipboard action.
local vim = require("psi.extensions.vim_keybindings")
vim.enable(psi)
local vim_reads = 0
local vim_insert = rt._debug_edit_keys("ab", 1, { { key = "ctrl-v" } }, false, {
  clipboard_reader = function()
    vim_reads = vim_reads + 1
    return "Q"
  end,
})
local vim_normal = rt._debug_edit_keys(
  "ab",
  0,
  {
    { key = "escape" },
    { key = "ctrl-v" },
  },
  false,
  {
    clipboard_reader = function()
      vim_reads = vim_reads + 1
      return "wrong"
    end,
  }
)
vim.disable(psi)

return table.concat({
  pasted.input,
  tostring(pasted.cursor),
  pasted.status_text or "",
  unavailable.input,
  tostring(unavailable.cursor),
  unavailable.status_text or "",
  bracketed.input,
  tostring(bracketed_reads),
  vim_insert.input,
  tostring(vim_insert.cursor),
  vim_normal.editor_mode,
  vim_normal.selection_kind or "",
  tostring(vim_reads - 1),
}, "|")
