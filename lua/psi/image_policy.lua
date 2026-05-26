-- psi.image_policy: shared image-attachment gates.

local settings = require("psi.settings_manager")

local M = {}

M.DISABLED_TEXT = "Image reading is disabled."

function M.blocked()
  local cfg = settings.get("images", nil)
  if type(cfg) ~= "table" then
    return false
  end
  return cfg.block_images == true or cfg.blockImages == true
end

return M
