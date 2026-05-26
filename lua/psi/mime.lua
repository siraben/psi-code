-- psi.mime: small content sniffers for model-visible attachments.

local M = {}

local IMAGE_TYPE_SNIFF_BYTES = 4100
M.IMAGE_TYPE_SNIFF_BYTES = IMAGE_TYPE_SNIFF_BYTES

local function byte_at(data, index)
  return data:byte(index, index)
end

local function starts_with(data, prefix)
  return type(data) == "string" and data:sub(1, #prefix) == prefix
end

local function starts_with_ascii(data, offset, text)
  return type(data) == "string" and data:sub(offset + 1, offset + #text) == text
end

local function read_uint32_be(data, offset)
  return ((byte_at(data, offset + 1) or 0) * 0x1000000)
    + ((byte_at(data, offset + 2) or 0) << 16)
    + ((byte_at(data, offset + 3) or 0) << 8)
    + (byte_at(data, offset + 4) or 0)
end

local PNG_SIGNATURE = string.char(0x89) .. "PNG\r\n" .. string.char(0x1a) .. "\n"

local function is_png(data)
  return #data >= 16
    and read_uint32_be(data, #PNG_SIGNATURE) == 13
    and starts_with_ascii(data, 12, "IHDR")
end

local function is_animated_png(data)
  local offset = #PNG_SIGNATURE
  while offset + 8 <= #data do
    local chunk_length = read_uint32_be(data, offset)
    local chunk_type_offset = offset + 4
    if starts_with_ascii(data, chunk_type_offset, "acTL") then
      return true
    end
    if starts_with_ascii(data, chunk_type_offset, "IDAT") then
      return false
    end

    local next_offset = offset + 8 + chunk_length + 4
    if next_offset <= offset or next_offset > #data then
      return false
    end
    offset = next_offset
  end
  return false
end

function M.detect_supported_image_mime_from_bytes(data)
  if type(data) ~= "string" or data == "" then
    return nil
  end
  if byte_at(data, 1) == 0xff and byte_at(data, 2) == 0xd8 and byte_at(data, 3) == 0xff then
    if byte_at(data, 4) == 0xf7 then
      return nil
    end
    return "image/jpeg"
  end
  if starts_with(data, PNG_SIGNATURE) then
    return is_png(data) and not is_animated_png(data) and "image/png" or nil
  end
  if starts_with_ascii(data, 0, "GIF") then
    return "image/gif"
  end
  if starts_with_ascii(data, 0, "RIFF") and starts_with_ascii(data, 8, "WEBP") then
    return "image/webp"
  end
  return nil
end

function M.detect_supported_image_mime_from_file(path)
  if type(path) ~= "string" or path == "" or not psi.read_file_prefix then
    return nil
  end
  return M.detect_supported_image_mime_from_bytes(
    psi.read_file_prefix(path, IMAGE_TYPE_SNIFF_BYTES)
  )
end

return M
