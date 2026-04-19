-- psi.io: safe file read.

local M = {}

function M.safe_read(path)
  if path and psi.file_exists(path) then
    return psi.read_file(path)
  end
  return nil
end

return M
