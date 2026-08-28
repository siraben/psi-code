--[==[psi-test
expect = "true|true|true|true|true"
]==]
local text = require("psi.tui_text")
local runtime = require("psi.tui_runtime")

local conjuncts = {
  "क्ष", -- Devanagari
  "ক্ষ", -- Bengali
  "ક્ષ", -- Gujarati
  "କ୍ଷ", -- Odia
  "క్ష", -- Telugu
  "ക്ഷ", -- Malayalam
  "က္က", -- Myanmar
  "ក្ក", -- Khmer
  "ᬓ᭄ᬓ", -- Balinese
  "ꦏ꧀ꦏ", -- Javanese
}

local function atomic_editing(unit)
  local input = "A" .. unit .. "B"
  local after = 1 + #unit
  local moved = runtime._debug_edit_keys(input, 1, { { key = "right" } }, false)
  local erased = runtime._debug_edit_keys(input, after, { { key = "backspace" } }, false)
  return moved.cursor == after and erased.input == "AB" and erased.cursor == 1
end

local atomic = true
local widths = true
for _, unit in ipairs(conjuncts) do
  atomic = atomic and text.next_grapheme_index(unit, 0) == #unit and atomic_editing(unit)
  widths = widths and text.visible_width(unit) == 2
end

local devanagari_zwj = "क्‍ष"
local devanagari_chain = "क्ष्ण"
local devanagari_zwnj = "क्‌ष"
local devanagari_zwnj_relink = "क्‌्‍ष"
local bare_zwj = "क‍ष"
local controls = text.next_grapheme_index(devanagari_zwj, 0) == #devanagari_zwj
  and text.visible_width(devanagari_zwj) == 2
  and text.next_grapheme_index(devanagari_chain, 0) == #devanagari_chain
  and text.visible_width(devanagari_chain) == 3
  and text.next_grapheme_index(devanagari_zwnj, 0) == #"क्‌"
  and text.next_grapheme_index(devanagari_zwnj_relink, 0) == #"क्‌्‍"
  and text.next_grapheme_index(bare_zwj, 0) == #"क‍"

local corpus = {
  "A",
  "é",
  "👩‍💻",
  devanagari_zwj,
  devanagari_chain,
  devanagari_zwnj,
  devanagari_zwnj_relink,
  bare_zwj,
}
for _, unit in ipairs(conjuncts) do
  corpus[#corpus + 1] = unit
end

local parity = true
for _, left in ipairs(corpus) do
  for _, right in ipairs(corpus) do
    local value = left .. right
    local width = text.visible_width(value)
    parity = parity and text._debug_fallback_visible_width(value) == width
    for column = 0, width + 1 do
      parity = parity
        and text._debug_fallback_byte_index_for_width(value, column)
          == text.byte_index_for_width(value, column)
    end
  end
end

return table.concat({
  tostring(atomic),
  tostring(widths),
  tostring(controls),
  tostring(atomic_editing(devanagari_zwj) and atomic_editing(devanagari_chain)),
  tostring(parity),
}, "|")
