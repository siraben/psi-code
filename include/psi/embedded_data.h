#ifndef PSI_EMBEDDED_DATA_H
#define PSI_EMBEDDED_DATA_H

#include <stddef.h>

/* DEFLATE-compressed data embedded in the psi binary. */
struct psi_embedded_data {
    const char *name;
    const unsigned char *src;
    size_t len;
    size_t raw_len;
};

/* Lua modules, keyed by module name: lua/psi/prelude.lua -> psi.prelude. */
extern const struct psi_embedded_data psi_embedded_lua_table[];

/* Documentation, keyed by source-relative path. */
extern const struct psi_embedded_data psi_embedded_docs_table[];

/* Optional CA bundle, populated when EMBED_CA_FILE is set. */
extern const struct psi_embedded_data psi_embedded_ca_table[];

#endif
