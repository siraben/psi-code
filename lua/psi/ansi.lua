-- psi.ansi: ANSI color helpers.

local M = {}

local ESC = string.char(27)

function M.color(code, text)
  return ESC .. "[" .. code .. "m" .. text .. ESC .. "[0m"
end
function M.bold(text)
  return M.color("1", text)
end
function M.dim(text)
  return M.color("2", text)
end
function M.cyan(text)
  return M.color("36", text)
end
function M.green(text)
  return M.color("32", text)
end
function M.red(text)
  return M.color("31", text)
end
function M.yellow(text)
  return M.color("33", text)
end

return M
