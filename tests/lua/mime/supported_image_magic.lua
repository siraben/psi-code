--[==[psi-test
expect = "image/png|nil|image/jpeg|nil|image/gif|image/webp|nil"
]==]
local mime = require("psi.mime")
local sig = string.char(0x89) .. "PNG\r\n" .. string.char(0x1a) .. "\n"
local png = sig .. string.char(0, 0, 0, 13) .. "IHDR"
local png_sig_only = sig
local jpg = string.char(0xff, 0xd8, 0xff, 0xdb)
local jpg_ls = string.char(0xff, 0xd8, 0xff, 0xf7)
local gif = "GIF89a"
local webp = "RIFF" .. string.char(0, 0, 0, 0) .. "WEBP"
return table.concat({
  tostring(mime.detect_supported_image_mime_from_bytes(png)),
  tostring(mime.detect_supported_image_mime_from_bytes(png_sig_only)),
  tostring(mime.detect_supported_image_mime_from_bytes(jpg)),
  tostring(mime.detect_supported_image_mime_from_bytes(jpg_ls)),
  tostring(mime.detect_supported_image_mime_from_bytes(gif)),
  tostring(mime.detect_supported_image_mime_from_bytes(webp)),
  tostring(mime.detect_supported_image_mime_from_bytes("hello")),
}, "|")
