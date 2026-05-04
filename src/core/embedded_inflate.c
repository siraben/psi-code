/* Minimal inflater for the embedded-blob table.
 *
 * Used by the ESP firmware build (where src/lua/vm.c, which carries
 * the zlib-backed inflate path, isn't compiled). Every other build
 * uses vm.c's definition.
 *
 * The firmware always embeds with --no-compress (raw_len == len) so
 * inflate is just a memcpy. If the linker ever sees a compressed
 * entry come through this path we log loudly and fail rather than
 * try to pull zlib in. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "psi/common.h"
#include "psi/embedded_data.h"

int psi_embedded_inflate(const struct psi_embedded_data *e, unsigned char *out, size_t out_len) {
    if (e == NULL || e->src == NULL || out == NULL)
        return PSI_STATUS_ERROR;
    if (out_len < e->raw_len)
        return PSI_STATUS_ERROR;
    if (e->len == e->raw_len) {
        memcpy(out, e->src, e->raw_len);
        return PSI_STATUS_OK;
    }
    fprintf(stderr, "psi: compressed embed entry %s but no zlib linked\n",
        e->name != NULL ? e->name : "?");
    return PSI_STATUS_ERROR;
}
