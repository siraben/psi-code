-- psi.text_decode: Small text decoding helpers for model-visible tool output.

local M = {}

local REPLACEMENT = "\239\191\189"

local function utf8_char(cp)
  if cp < 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
    return REPLACEMENT
  elseif cp <= 0x7F then
    return string.char(cp)
  elseif cp <= 0x7FF then
    return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
  elseif cp <= 0xFFFF then
    return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  end
  return string.char(
    0xF0 | (cp >> 18),
    0x80 | ((cp >> 12) & 0x3F),
    0x80 | ((cp >> 6) & 0x3F),
    0x80 | (cp & 0x3F)
  )
end

local function unit_at(text, i, endian)
  local a, b = string.byte(text, i, i + 1)
  if not a or not b then
    return nil
  end
  if endian == "le" then
    return a | (b << 8)
  end
  return (a << 8) | b
end

local function decode_utf16(text, endian, start_i)
  local out = {}
  local replacements = 0
  local controls = 0
  local printable = 0
  local i = start_i or 1
  local n = #text

  while i <= n do
    local unit = unit_at(text, i, endian)
    local cp = unit
    i = i + 2

    if not unit then
      cp = 0xFFFD
      replacements = replacements + 1
    elseif unit >= 0xD800 and unit <= 0xDBFF then
      local next_unit = unit_at(text, i, endian)
      if next_unit and next_unit >= 0xDC00 and next_unit <= 0xDFFF then
        cp = 0x10000 + (((unit - 0xD800) << 10) | (next_unit - 0xDC00))
        i = i + 2
      else
        cp = 0xFFFD
        replacements = replacements + 1
      end
    elseif unit >= 0xDC00 and unit <= 0xDFFF then
      cp = 0xFFFD
      replacements = replacements + 1
    end

    if cp == 0xFFFD then
      out[#out + 1] = REPLACEMENT
    else
      out[#out + 1] = utf8_char(cp)
    end
    if cp == 9 or cp == 10 or cp == 13 or cp >= 32 then
      printable = printable + 1
    else
      controls = controls + 1
    end
  end

  return table.concat(out),
    {
      controls = controls,
      printable = printable,
      replacements = replacements,
    }
end

local function null_pattern(text)
  local odd = 0
  local even = 0
  local sampled = math.min(#text, 4096)
  for i = 1, sampled do
    if string.byte(text, i) == 0 then
      if (i % 2) == 1 then
        odd = odd + 1
      else
        even = even + 1
      end
    end
  end
  return odd, even, sampled
end

local function score(meta)
  return (meta.printable * 4) - (meta.controls * 8) - (meta.replacements * 16)
end

local function choose_candidate(candidates)
  local best = candidates[1]
  for i = 2, #candidates do
    if score(candidates[i].meta) > score(best.meta) then
      best = candidates[i]
    end
  end
  return best
end

function M.utf16_to_utf8(text)
  if type(text) ~= "string" or text == "" then
    return text or nil, nil
  end

  local b1, b2 = string.byte(text, 1, 2)
  if b1 == 0xFF and b2 == 0xFE then
    local decoded = decode_utf16(text, "le", 3)
    return decoded, "utf-16le"
  elseif b1 == 0xFE and b2 == 0xFF then
    local decoded = decode_utf16(text, "be", 3)
    return decoded, "utf-16be"
  end

  local odd_nuls, even_nuls, sampled = null_pattern(text)
  local dominant_nuls = math.max(odd_nuls, even_nuls)
  local other_nuls = math.min(odd_nuls, even_nuls)
  local aligned_after_delimiter = b1 == 0 and (#text % 2) == 1 and #text >= 3
  if
    not aligned_after_delimiter
    and (
      sampled < 4
      or dominant_nuls < math.max(2, math.floor(sampled / 8))
      or dominant_nuls < (other_nuls * 2 + 1)
    )
  then
    return text, nil
  end

  local candidates = {}
  local le_text, le_meta = decode_utf16(text, "le", 1)
  candidates[#candidates + 1] = { text = le_text, meta = le_meta, encoding = "utf-16le" }
  local be_text, be_meta = decode_utf16(text, "be", 1)
  candidates[#candidates + 1] = { text = be_text, meta = be_meta, encoding = "utf-16be" }

  if b1 == 0 and (#text % 2) == 1 then
    local aligned_text, aligned_meta = decode_utf16(text, "le", 2)
    candidates[#candidates + 1] =
      { text = aligned_text, meta = aligned_meta, encoding = "utf-16le" }
  end

  local best = choose_candidate(candidates)
  return best.text, best.encoding
end

return M
