-- Optional palettes from pi-mono 6f755151, not the installed Pi 0.84.4.

local dark = {
  -- Current pi-mono dark theme color aliases, translated from OKHSL to
  -- truecolor SGR. See packages/coding-agent/.../theme/dark.json.
  ansi = {
    ["2"] = "38;2;126;136;142", -- dim
    ["31"] = "38;2;234;127;129", -- error/red
    ["32"] = "38;2;104;183;141", -- success/green
    ["33"] = "38;2;205;154;34", -- warning/yellow
    ["34"] = "38;2;95;168;204", -- border/blue
    ["36"] = "38;2;167;152;215", -- accent/violet
    ["37"] = "38;2;222;224;225", -- text
    ["90"] = "38;2;126;136;142",
    ["96"] = "38;2;167;152;215",
    ["1;36"] = "1;38;2;167;152;215",
    ["38;5;242"] = "38;2;157;165;169", -- muted/toolOutput
    ["38;5;245"] = "38;2;157;165;169",
    ["38;5;81"] = "38;2;167;152;215",
    ["38;5;108"] = "38;2;104;183;141",
    ["38;5;174"] = "38;2;234;127;129",
    ["38;5;221"] = "38;2;205;154;34",
    ["48;5;236"] = "48;2;52;56;58",
    ["48;5;22"] = "48;2;37;65;49",
    ["48;5;52"] = "48;2;91;40;42",
    ["48;5;237"] = "48;2;33;59;73",
    ["48;5;238"] = "48;2;33;59;73",
    ["md-link"] = "38;2;105;173;208",
    ["md-link-url"] = "38;2;157;165;169",
    ["md-heading"] = "38;2;205;154;34",
    ["md-bullet"] = "38;2;167;152;215",
    ["thinking-text"] = "38;2;150;160;164",
    ["bash-mode"] = "38;2;94;178;134",
    ["thinking-off"] = "38;2;108;118;123",
    ["thinking-minimal"] = "38;2;104;128;141",
    ["thinking-low"] = "38;2;84;137;164",
    ["thinking-medium"] = "38;2;97;133;204",
    ["thinking-high"] = "38;2;151;118;229",
    ["thinking-xhigh"] = "38;2;222;84;193",
    ["thinking-max"] = "38;2;254;84;98",
  },
  tui = {
    header = { fg = 74, bg = 234 },
    accent = { fg = 140, bg = 234 },
    text = { fg = 254, bg = 234 },
    warning = { fg = 178, bg = 234 },
    success = { fg = 108, bg = 234 },
    error = { fg = 174, bg = 234 },
    chrome = { fg = 247, bg = 234 },
    thinking_off = { fg = 243, bg = 234 },
    thinking_minimal = { fg = 66, bg = 234 },
    thinking_low = { fg = 67, bg = 234 },
    thinking_medium = { fg = 68, bg = 234 },
    thinking_high = { fg = 141, bg = 234 },
    thinking_xhigh = { fg = 170, bg = 234 },
    thinking_max = { fg = 203, bg = 234 },
  },
}

-- pi-mono 6f755151 light theme, translated to SGR.
-- The tool background tints are deliberately pale so that the dark
-- toolTitle/text stays legible; the dark theme uses the inverse.
local light = {
  ansi = {
    ["2"] = "38;2;135;144;149", -- dim
    ["31"] = "38;2;200;37;61", -- error/red
    ["32"] = "38;2;51;126;88", -- success/green
    ["33"] = "38;2;143;104;2", -- warning/yellow
    ["34"] = "38;2;61;142;179", -- border/blue
    ["36"] = "38;2;116;89;180", -- accent/violet
    ["37"] = "38;2;59;63;65", -- text
    ["90"] = "38;2;135;144;149",
    ["96"] = "38;2;116;89;180",
    ["1;36"] = "1;38;2;116;89;180",
    ["38;5;242"] = "38;2;103;113;118", -- muted/toolOutput
    ["38;5;245"] = "38;2;103;113;118",
    ["38;5;81"] = "38;2;116;89;180",
    ["38;5;108"] = "38;2;51;126;88",
    ["38;5;174"] = "38;2;200;37;61",
    ["38;5;221"] = "38;2;143;104;2",
    ["48;5;236"] = "48;2;228;229;230",
    ["48;5;22"] = "48;2;222;233;225",
    ["48;5;52"] = "48;2;238;226;225",
    ["48;5;237"] = "48;2;223;231;236",
    ["48;5;238"] = "48;2;223;231;236",
    ["md-link"] = "38;2;47;120;153",
    ["md-link-url"] = "38;2;103;113;118",
    ["md-heading"] = "38;2;143;104;2",
    ["md-bullet"] = "38;2;116;89;180",
    ["thinking-text"] = "38;2;124;134;140",
    ["bash-mode"] = "38;2;64;151;108",
    ["thinking-off"] = "38;2;194;200;202",
    ["thinking-minimal"] = "38;2;181;196;203",
    ["thinking-low"] = "38;2;159;194;213",
    ["thinking-medium"] = "38;2;162;183;224",
    ["thinking-high"] = "38;2;181;165;232",
    ["thinking-xhigh"] = "38;2;229;133;205",
    ["thinking-max"] = "38;2;254;116;121",
  },
  tui = {
    header = { fg = 31, bg = 255 },
    accent = { fg = 97, bg = 255 },
    text = { fg = 238, bg = 255 },
    warning = { fg = 136, bg = 255 },
    success = { fg = 29, bg = 255 },
    error = { fg = 161, bg = 255 },
    chrome = { fg = 243, bg = 255 },
    thinking_off = { fg = 251, bg = 255 },
    thinking_minimal = { fg = 250, bg = 255 },
    thinking_low = { fg = 153, bg = 255 },
    thinking_medium = { fg = 147, bg = 255 },
    thinking_high = { fg = 183, bg = 255 },
    thinking_xhigh = { fg = 176, bg = 255 },
    thinking_max = { fg = 210, bg = 255 },
  },
}

return { dark = dark, light = light }
