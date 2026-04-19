-- Luacheck configuration for psi.

std = "lua54"

-- `psi` is the FFI table the C runtime installs before boot.lua runs.
globals = {"psi"}

-- boot.lua intentionally mutates the psi global to attach module tables.
files["lua/boot.lua"] = {
  globals = {"psi"},
}

-- Silence warnings for unused self-assigned loop variables (common in
-- callback shapes) and the common "line too long" nit.
ignore = {
  "212", -- unused argument
  "631", -- line too long
}
