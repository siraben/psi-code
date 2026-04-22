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

/* Each entry is DEFLATE-compressed (zlib compress2 level 9). The
 * runtime inflates on first access before handing the bytes to
 * luaL_loadbuffer or the read tool. `len` is the compressed size
 * baked into the C array; `raw_len` is the size the caller must
 * allocate for the inflated output. */
struct psi_embedded_lua {
    const char *name;
    const unsigned char *src;
    size_t len;
    size_t raw_len;
};

/* Lua modules (boot.lua + psi/ modules). Keyed by module name. */
extern const struct psi_embedded_lua psi_embedded_lua_table[];

/* Documentation (README.md + docs/ markdown). Keyed by the relative
 * path as it appears in the source tree ("README.md",
 * "docs/architecture.md"). Exposed to Lua via psi.embedded_doc(path);
 * the `read` tool falls back to this table when a requested file
 * isn't on disk, so the agent can self-describe even on machines
 * where the source tree isn't present. */
extern const struct psi_embedded_lua psi_embedded_docs_table[];

#endif
