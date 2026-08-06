-- psi.glyphs: symbol set with ASCII fallbacks.
--
-- `M.enabled` gates the preferred (non-ASCII) forms. Callers don't branch on
-- it themselves; they read `M.bullet` / `M.hrule` / etc. and get an ASCII
-- stand-in when the terminal's charset can't represent the preferred glyph.
--
-- This is deliberately separate from psi.ansi: charset support and escape
-- sequence support are independent capabilities. A terminal in a non-UTF-8
-- locale renders colour correctly but turns box drawing into mojibake or
-- missing-glyph boxes, so a single "fancy output" flag would get it wrong.

local M = {}
local platform = require("psi.platform")

-- name = { preferred, ascii }
local GLYPHS = {
  bullet = { "•", "*" },
  quote_bar = { "│ ", "| " },
  hrule = { "─", "-" },
  vbar = { "│", "|" },
  corner_up = { "╰─", "\\-" },
  arrow_return = { "↳", ">" },
  prompt_caret = { "›", ">" },
  dash = { "—", "--" },
  ellipsis = { "…", "..." },
  radio_on = { "◉", "(*)" },
  radio_off = { "○", "( )" },
  dot = { "•", "*" },
}

local SPINNERS = {
  { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  { "|", "/", "-", "\\" },
}

function M.set_enabled(on)
  M.enabled = on and true or false
  local index = M.enabled and 1 or 2
  for name, forms in pairs(GLYPHS) do
    M[name] = forms[index]
  end
  M.spinner = SPINNERS[index]
end

-- Re-read the environment. Exposed for tests and for callers that change
-- locale or the override after startup.
function M.refresh()
  M.set_enabled(platform.unicode_supported())
end

M.refresh()

return M
