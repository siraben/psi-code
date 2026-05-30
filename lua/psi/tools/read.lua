-- psi.tools.read: Read a file with offset/limit paging and head-truncation.

local records = require("psi.records")
local registry = require("psi.tool_registry")
local path_util = require("psi.path_utils")
local helpers = require("psi.tool_helpers")
local image_policy = require("psi.image_policy")
local mime = require("psi.mime")
local text_decode = require("psi.text_decode")
local truncate = require("psi.truncate")

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local TEXT_READ_MAX_BYTES = truncate.DEFAULT_MAX_BYTES
local INLINE_IMAGE_BASE64_LIMIT_BYTES = 4718592
local INLINE_IMAGE_RAW_LIMIT_BYTES = math.floor(INLINE_IMAGE_BASE64_LIMIT_BYTES * 3 / 4)
local NON_VISION_IMAGE_NOTE =
  "[Current model does not support images. The image will be omitted from this request.]"

local function byte_at(text, index)
  return text:byte(index, index) or 0
end

local function base64_char(index)
  return BASE64_ALPHABET:sub(index + 1, index + 1)
end

local function base64_encode(text)
  text = tostring(text or "")
  local out = {}
  local out_index = 0
  for index = 1, #text, 3 do
    local first = byte_at(text, index)
    local second = byte_at(text, index + 1)
    local third = byte_at(text, index + 2)
    local triple = (first << 16) | (second << 8) | third
    local remaining = #text - index + 1

    out_index = out_index + 1
    out[out_index] = base64_char((triple >> 18) & 0x3f)
    out_index = out_index + 1
    out[out_index] = base64_char((triple >> 12) & 0x3f)
    out_index = out_index + 1
    out[out_index] = remaining >= 2 and base64_char((triple >> 6) & 0x3f) or "="
    out_index = out_index + 1
    out[out_index] = remaining >= 3 and base64_char(triple & 0x3f) or "="
  end
  return table.concat(out)
end

local function byte_preview(bytes)
  local hex = {}
  local ascii = {}
  for i = 1, #bytes do
    local b = bytes:byte(i)
    hex[#hex + 1] = string.format("%02X", b)
    if b >= 32 and b < 127 then
      ascii[#ascii + 1] = string.char(b)
    else
      ascii[#ascii + 1] = "."
    end
  end
  return table.concat(hex, " ") .. "\n" .. table.concat(ascii)
end

local function model_supports_images(meta)
  if type(meta) ~= "table" or type(meta.model) ~= "string" or meta.model == "" then
    return nil
  end
  local id = meta.model
  if type(meta.provider) == "string" and meta.provider ~= "" and not id:match("^[^/]+/") then
    id = meta.provider .. "/" .. id
  end

  local ok, api_registry = pcall(require, "psi.api_registry")
  local model = ok and api_registry and api_registry.model and api_registry.model(id) or nil
  local input = type(model) == "table" and model.input or nil
  if type(input) ~= "table" then
    return nil
  end
  for _, modality in ipairs(input) do
    if modality == "image" then
      return true
    end
  end
  return false
end

local function image_read_limit_text()
  return "4.5 MiB base64 payload"
end

local function notice(page)
  if not page or not page.truncated then
    return nil
  end
  local start_line = page.offset or 1
  local end_line = math.min(page.total_lines or 0, start_line + (page.limit or 0) - 1)
  local parts = {
    "[Showing lines ",
    tostring(start_line),
    "-",
    tostring(end_line),
    " of ",
    tostring(page.total_lines or 0),
    ".",
  }
  if page.next_offset then
    parts[#parts + 1] = " Use offset="
    parts[#parts + 1] = tostring(page.next_offset)
    parts[#parts + 1] = " to continue."
  end
  if page.truncated_bytes then
    parts[#parts + 1] = " Byte limit reached."
  end
  parts[#parts + 1] = "]"
  return table.concat(parts)
end

local function normalize_offset(value)
  value = tonumber(value)
  if value == nil then
    return 1
  end
  value = math.floor(value)
  if value < 1 then
    return 1
  end
  return value
end

local function to_public_slice(slice, public_offset)
  if type(slice) ~= "table" then
    return slice
  end
  slice.offset = public_offset
  if slice.next_offset then
    slice.next_offset = slice.next_offset + 1
  end
  return slice
end

local function impl(input, meta)
  local raw_path = registry.require_string(input, "path")
  if not raw_path then
    return records.tool_failure("read", "missing string field: path")
  end
  local resolved = path_util.resolve(raw_path) or raw_path
  local offset = normalize_offset(registry.optional_number(input, "offset", 1))
  local internal_offset = offset - 1
  local limit = registry.optional_number(input, "limit", 2000)
  local mode = registry.optional_string(input, "mode", "text")
  local source = nil
  local slice = nil

  local kind = psi.file_type and psi.file_type(resolved) or nil
  if kind == "file" then
    if mode == "bytes" or mode == "binary" then
      local byte_slice = psi.read_file_bytes(resolved, offset, limit)
      if type(byte_slice) == "table" and type(byte_slice.bytes) == "string" then
        local text = byte_preview(byte_slice.bytes)
        if byte_slice.truncated then
          text = string.format(
            "[Showing bytes %d-%d of %d. Use offset=%d to continue.]\n%s",
            byte_slice.offset,
            byte_slice.offset + byte_slice.limit - 1,
            byte_slice.total_bytes,
            byte_slice.next_offset or (byte_slice.offset + byte_slice.limit),
            text
          )
        end
        return records.new_tool_result(true, "read", nil, {
          path = raw_path,
          resolved_path = path_util.to_host(resolved),
          internal_path = resolved,
          mode = "bytes",
          text = text,
          offset = byte_slice.offset,
          limit = byte_slice.limit,
          total_bytes = byte_slice.total_bytes,
          next_offset = byte_slice.next_offset,
          truncated = byte_slice.truncated,
        })
      end
    end

    local mime_type = mime.detect_supported_image_mime_from_file(resolved)
    if mime_type then
      if image_policy.blocked() then
        local text = "Read image file [" .. mime_type .. "]\n[" .. image_policy.DISABLED_TEXT .. "]"
        return records.new_tool_result(true, "read", nil, {
          path = raw_path,
          resolved_path = path_util.to_host(resolved),
          internal_path = resolved,
          text = text,
          content = { { type = "text", text = text } },
          image = false,
          image_omitted = image_policy.DISABLED_TEXT,
          mimeType = mime_type,
          offset = offset,
          limit = limit,
        })
      end
      local data = psi.read_file_limited
          and psi.read_file_limited(resolved, INLINE_IMAGE_RAW_LIMIT_BYTES)
        or psi.read_file(resolved)
      local text = "Read image file [" .. mime_type .. "]"
      if model_supports_images(meta) == false then
        text = text .. "\n" .. NON_VISION_IMAGE_NOTE
      end
      local content = { { type = "text", text = text } }
      local omitted = nil
      if type(data) == "string" then
        content[#content + 1] = { type = "image", data = base64_encode(data), mimeType = mime_type }
      else
        omitted = "image exceeds psi inline image limit ("
          .. image_read_limit_text()
          .. ") or could not be read; psi does not auto-resize images"
        text = text .. "\n[Image omitted: " .. omitted .. ".]"
        content[1].text = text
      end
      return records.new_tool_result(true, "read", nil, {
        path = raw_path,
        resolved_path = path_util.to_host(resolved),
        internal_path = resolved,
        text = text,
        content = content,
        image = omitted == nil,
        image_omitted = omitted,
        mimeType = mime_type,
        bytes = type(data) == "string" and #data or nil,
        offset = offset,
        limit = limit,
      })
    else
      slice = to_public_slice(
        psi.read_file_slice(resolved, internal_offset, limit, TEXT_READ_MAX_BYTES),
        offset
      )
    end
  elseif kind ~= nil then
    return records.tool_failure("read", "Cannot read file: " .. tostring(raw_path))
  else
    local embedded = psi.embedded_doc and psi.embedded_doc(raw_path) or nil
    if embedded then
      local text, embedded_meta = truncate.by_lines(embedded, internal_offset, limit)
      slice = {
        text = text,
        total_lines = embedded_meta.total_lines,
        next_offset = embedded_meta.next_offset and (embedded_meta.next_offset + 1) or nil,
        truncated = embedded_meta.truncated,
        offset = offset,
        limit = limit,
      }
      source = "embedded"
    end
  end

  if type(slice) == "table" and type(slice.text) == "string" then
    local text = text_decode.utf16_to_utf8(slice.text)
    local msg = notice(slice)
    if msg then
      text = msg .. "\n" .. text
    end
    return records.new_tool_result(true, "read", nil, {
      path = raw_path,
      resolved_path = path_util.to_host(resolved),
      internal_path = resolved,
      text = text,
      source = source,
      offset = offset,
      limit = limit,
      mode = "text",
      total_lines = slice.total_lines,
      next_offset = slice.next_offset,
      truncated = slice.truncated,
    })
  end
  return records.tool_failure("read", "no such file: " .. tostring(raw_path))
end

return function()
  helpers.register(registry, records, {
    name = "read",
    description = "Read the contents of a file. Supports text files, images (jpg, png, gif, webp), and mode='bytes' for binary byte ranges rendered as hex/ascii. Images are sent as attachments when image reading is enabled. For text files, output is truncated to 2000 lines or 50KB (whichever is hit first). Use offset/limit for large files. When you need the full file, continue with offset until complete. Oversized images are omitted because psi does not auto-resize images.",
    prompt_snippet = "Read file contents",
    guidelines = { "Use read to examine files instead of cat or sed." },
    input_schema = helpers.schema_object({
      path = helpers.schema_type("string"),
      offset = helpers.schema_type("number"),
      limit = helpers.schema_type("number"),
      mode = helpers.schema_type("string"),
    }, { "path" }),
    impl = impl,
  })
end
