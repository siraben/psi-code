#ifndef PSI_HTTP_BUFFERED_H
#define PSI_HTTP_BUFFERED_H

#include "psi/common.h"

struct psi_abort_signal;

/* Generic HTTP primitives exposed to Lua. The agent turn loop lives
 * in lua/psi/anthropic.lua; this header is just the minimum C surface
 * needed for Lua to POST to Anthropic's API (or any other provider). */

int psi_http_post(const char *url, const char *const *header_lines, size_t header_count,
    const char *body, size_t body_len, const struct psi_abort_signal *abort_signal,
    long *status_code, char **response_body, char **error_message);

int psi_http_get(const char *url, const char *const *header_lines, size_t header_count,
    const struct psi_abort_signal *abort_signal, long *status_code, char **response_body,
    char **error_message);

#endif
