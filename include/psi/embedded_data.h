#ifndef PSI_EMBEDDED_DATA_H
#define PSI_EMBEDDED_DATA_H

#include <stddef.h>
#include "psi/common.h"

/* DEFLATE-compressed data embedded in the psi binary. */
struct psi_embedded_data {
    const char *name;
    const unsigned char *src;
    size_t len;
    size_t raw_len;
};

/* Inflate one entry into the caller-provided buffer. The buffer must
 * be at least entry->raw_len bytes. Returns PSI_STATUS_OK on success.
 * Implemented in src/lua/vm.c so the ESP backend (and any other
 * consumer of the embed table) can decompress entries without
 * duplicating the zlib glue. */
struct psi_embedded_data;
int psi_embedded_inflate(
    const struct psi_embedded_data *entry, unsigned char *out, size_t out_len);

/* Lua modules, keyed by module name: lua/psi/prelude.lua -> psi.prelude. */
extern const struct psi_embedded_data psi_embedded_lua_table[];

/* Documentation, keyed by source-relative path. */
extern const struct psi_embedded_data psi_embedded_docs_table[];

/* Optional CA bundle, populated when EMBED_CA_FILE is set. */
extern const struct psi_embedded_data psi_embedded_ca_table[];

#endif
