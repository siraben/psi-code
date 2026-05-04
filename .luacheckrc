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

-- storage.lua deliberately overrides io.open / os.remove / etc. so the
-- agent's standard-library calls go through psi's capability gates and
-- ramfs lookups instead of touching the host. These are by-design
-- shadows, not accidents.
files["lua/psi/storage.lua"] = {
  ignore = {
    "121", -- setting read-only global variable
    "122", -- setting read-only field of global
  },
}
