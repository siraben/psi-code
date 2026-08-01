--[==[psi-test
expect = "1|3|6|17|25|28|25|17|6|3"
]==]
local text = require("psi.tui_text")
local value = "Aéé👩‍💻🇺🇸界"
local offsets = { 0 }
for _ = 1, 6 do
  offsets[#offsets + 1] = text.next_grapheme_index(value, offsets[#offsets])
end
local back = { offsets[#offsets] }
for _ = 1, 4 do
  back[#back + 1] = text.previous_grapheme_index(value, back[#back])
end
return table.concat({
  offsets[2],
  offsets[3],
  offsets[4],
  offsets[5],
  offsets[6],
  offsets[7],
  back[2],
  back[3],
  back[4],
  back[5],
}, "|")
