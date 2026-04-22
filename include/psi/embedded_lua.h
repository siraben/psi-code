#ifndef PSI_EMBEDDED_LUA_H
#define PSI_EMBEDDED_LUA_H

#include <stddef.h>

/* Lua modules shipped inside the psi binary.
 *
 * Populated at build time by scripts/embed_lua.c from every file
 * under lua/. The table is terminated by a {NULL, NULL, 0} sentinel.
 *
 * Module names are derived from the source path:
 *   lua/boot.lua        -> "boot"
 *   lua/psi/prelude.lua -> "psi.prelude"
 *
 * The VM registers a package.searchers entry (see psi_vm_init) that
 * walks this table; require("psi.X") succeeds without any filesystem
 * access. A user-supplied --boot=FILE still overrides the embedded
 * bootstrap for development. */

struct psi_embedded_lua {
    const char *name;
    const unsigned char *src;
    size_t len;
};

extern const struct psi_embedded_lua psi_embedded_lua_table[];

#endif
