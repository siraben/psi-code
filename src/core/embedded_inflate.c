/* Minimal inflater for the embedded-blob table.
 *
 * Used by the ESP firmware build (where src/lua/vm.c, which carries
 * the zlib-backed inflate path, isn't compiled). Every other build
 * uses vm.c's definition — gated with PSI_NO_ZLIB so the host link
 * doesn't see two definitions of psi_embedded_inflate.
 *
 * The firmware always embeds with --no-compress (raw_len == len) so
 * inflate is just a memcpy. If the linker ever sees a compressed
 * entry come through this path we log loudly and fail rather than
 * try to pull zlib in. */

#ifdef PSI_NO_ZLIB

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "psi/common.h"
#include "psi/embedded_data.h"

int psi_embedded_inflate(
    const struct psi_embedded_data *entry, unsigned char *out, size_t out_len) {
    if (entry == NULL || entry->src == NULL || out == NULL)
        return PSI_STATUS_ERROR;
    if (out_len < entry->raw_len)
        return PSI_STATUS_ERROR;
    if (entry->len == entry->raw_len) {
        memcpy(out, entry->src, entry->raw_len);
        return PSI_STATUS_OK;
    }
    fprintf(stderr, "psi: compressed embed entry %s but no zlib linked\n",
        entry->name != NULL ? entry->name : "?");
    return PSI_STATUS_ERROR;
}

#else /* !PSI_NO_ZLIB */

/* Avoid an ISO-C empty translation unit when zlib is linked: the host
 * build uses src/lua/vm.c's definition, leaving this file body
 * vacuous. A typedef satisfies pedantic without affecting the link. */
typedef int psi_embedded_inflate_no_op;

#endif /* PSI_NO_ZLIB */
