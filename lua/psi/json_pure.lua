-- psi.json: tiny pure-Lua JSON codec for hosts that cannot link cJSON.

local M = {}

local function is_array(t)
  local mt = getmetatable(t)
  if mt and mt.__jsontype == "array" then
    return true
  end
  local n = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
      return false
    end
    if k > n then
      n = k
    end
  end
  if n == 0 then
    return false
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return true
end

local escapes = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function quote(s)
  return '"'
    .. tostring(s):gsub('[%z\1-\31"\\]', function(c)
      return escapes[c] or string.format("\\u%04x", c:byte())
    end)
    .. '"'
end

local encode_value
encode_value = function(v)
  local tv = type(v)
  if tv == "nil" then
    return "null"
  end
  if tv == "boolean" then
    return v and "true" or "false"
  end
  if tv == "number" then
    return tostring(v)
  end
  if tv == "string" then
    return quote(v)
  end
  if tv == "table" then
    local out = {}
    if is_array(v) then
      for i = 1, #v do
        out[#out + 1] = encode_value(v[i])
      end
      return "[" .. table.concat(out, ",") .. "]"
    end
    for k, val in pairs(v) do
      if type(k) == "string" and k ~= "__kind" and k ~= "__jsontype" then
        out[#out + 1] = quote(k) .. ":" .. encode_value(val)
      end
    end
    table.sort(out)
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end

function M.encode(v)
  return encode_value(v)
end

local function decoder(text)
  local i, n = 1, #text

  local function err(msg)
    error("json decode error at byte " .. tostring(i) .. ": " .. msg, 0)
  end
  local function peek()
    return text:sub(i, i)
  end
  local function skip_ws()
    while i <= n and text:sub(i, i):match("%s") do
      i = i + 1
    end
  end

  local parse_value

  local function parse_string()
    if peek() ~= '"' then
      err("expected string")
    end
    i = i + 1
    local out = {}
    while i <= n do
      local c = text:sub(i, i)
      if c == '"' then
        i = i + 1
        return table.concat(out)
      elseif c == "\\" then
        local e = text:sub(i + 1, i + 1)
        if e == '"' or e == "\\" or e == "/" then
          out[#out + 1] = e
          i = i + 2
        elseif e == "b" then
          out[#out + 1] = "\b"
          i = i + 2
        elseif e == "f" then
          out[#out + 1] = "\f"
          i = i + 2
        elseif e == "n" then
          out[#out + 1] = "\n"
          i = i + 2
        elseif e == "r" then
          out[#out + 1] = "\r"
          i = i + 2
        elseif e == "t" then
          out[#out + 1] = "\t"
          i = i + 2
        elseif e == "u" then
          local hex = text:sub(i + 2, i + 5)
          if not hex:match("^%x%x%x%x$") then
            err("bad unicode escape")
          end
          local cp = tonumber(hex, 16)
          if cp < 128 then
            out[#out + 1] = string.char(cp)
          elseif cp < 2048 then
            out[#out + 1] = string.char(192 + math.floor(cp / 64), 128 + (cp % 64))
          else
            out[#out + 1] = string.char(
              224 + math.floor(cp / 4096),
              128 + (math.floor(cp / 64) % 64),
              128 + (cp % 64)
            )
          end
          i = i + 6
        else
          err("bad escape")
        end
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
    err("unterminated string")
  end

  local function parse_number()
    local s, e = text:find("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    if not s then
      err("expected number")
    end
    local num = tonumber(text:sub(s, e))
    if num == nil then
      err("bad number")
    end
    i = e + 1
    return num
  end

  local function parse_array()
    local out = {}
    i = i + 1
    skip_ws()
    if peek() == "]" then
      i = i + 1
      return setmetatable(out, { __jsontype = "array" })
    end
    while true do
      out[#out + 1] = parse_value()
      skip_ws()
      local c = peek()
      if c == "]" then
        i = i + 1
        return setmetatable(out, { __jsontype = "array" })
      end
      if c ~= "," then
        err("expected comma or ]")
      end
      i = i + 1
      skip_ws()
    end
  end

  local function parse_object()
    local out = {}
    i = i + 1
    skip_ws()
    if peek() == "}" then
      i = i + 1
      return out
    end
    while true do
      local key = parse_string()
      skip_ws()
      if peek() ~= ":" then
        err("expected colon")
      end
      i = i + 1
      out[key] = parse_value()
      skip_ws()
      local c = peek()
      if c == "}" then
        i = i + 1
        return out
      end
      if c ~= "," then
        err("expected comma or }")
      end
      i = i + 1
      skip_ws()
    end
  end

  parse_value = function()
    skip_ws()
    local c = peek()
    if c == '"' then
      return parse_string()
    end
    if c == "{" then
      return parse_object()
    end
    if c == "[" then
      return parse_array()
    end
    if text:sub(i, i + 3) == "true" then
      i = i + 4
      return true
    end
    if text:sub(i, i + 4) == "false" then
      i = i + 5
      return false
    end
    if text:sub(i, i + 3) == "null" then
      i = i + 4
      return nil
    end
    return parse_number()
  end

  local value = parse_value()
  skip_ws()
  if i <= n then
    err("trailing input")
  end
  return value
end

function M.decode(text)
  return decoder(text or "")
end

return M
